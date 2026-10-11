#!/system/bin/sh
# ============================================================
# hyperaudio — 模式状态机（取代原 mode_switch.sh）
# ============================================================
# 模式语义（对外保持不变）：
#   sound（音效模式）· 摘掉 low_latency_out / raw_out 的 FAST 标志
#                      · 停止 hyper-audio 守护进程
#   fast （低延迟模式）· 不加任何端口补丁（回到系统原始配置）
#                      · 启动 hyper-audio 守护进程
#
# 相对 0.4.5 的关键改动（可靠性）：
#   1) **只改自己的副本**：把调音模块提供的 audio_module_config_primary.xml
#      拷到本模块 state/base.xml，改写后生成 state/active.xml，
#      再 bind mount 到目标路径。全程不写调音模块的目录，
#      因此升级/禁用/卸载都不会留下被改过的第三方文件。
#   2) **不再先 umount**：直接把我们的层叠在原有挂载之上，
#      避免旧版"umount 成功但 mount 失败 => 该文件彻底失挂 => 无声"的窗口。
#   3) **端口改写改用 patch_ports.awk**：有界 XML 编辑器，异常一律 fail-closed，
#      不再依赖 sed 的多字节字符类行为。
#   4) **事务 + 回滚**：apply 前写 state/pending，失败即回滚到 native 并
#      明确报错；只有全部成功才写 state/applied 与 mode 文件。
#   5) **挂载所有权用证据判断**：stat dev:ino 比对 + /proc/self/mountinfo，
#      发现挂载已被别的模块替换则拒绝 umount（避免把别人的层摘掉）。
#   6) **开机护栏**：上次启动/切换未收尾时，自动降级为 native 并记录原因，
#      绝不在开机时反复重试一个已知失败的配置。
#
# 刻意**不采用** HyperAudio Switch 2.0 的两点：
#   · `setprop ctl.restart audioserver` —— 本机实测重启音频服务会让调音失效，
#     因此仍沿用 killall audioserver，且仅在 flags 真正变化时才做。
#   · 运行时改 aaudio 属性 / 替换 AAudio 库 —— 本模块继续用 system.prop 与预编译库。
#
# 用法: sh runtime.sh apply <sound|fast>
#       sh runtime.sh current
#       sh runtime.sh recover          # 撤销一切改动，回到系统原始状态
#       sh runtime.sh status
#       sh runtime.sh desc             # 只刷新 module.prop 的模式前缀
#       sh runtime.sh boot             # 开机调用（含护栏）
# ============================================================

MOD=${HA_MOD:-/data/adb/modules/hyperaudio}
STATE=$MOD/state
MODEFILE=$MOD/mode
MODPROP=$MOD/module.prop
PIDFILE=/data/local/tmp/hyperaudio.pid
DAEMON=$MOD/hyper-audio
STARTER=$MOD/bin/start_daemon.sh
PATCHER=$MOD/bin/patch_ports.awk
LOG=/data/local/tmp/hyper-audio.log
SH=/system/bin/sh
CR=$(printf '\r')

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> /data/local/tmp/hyperaudio-runtime.log 2>/dev/null; }
err() { echo "error=$*"; log "ERROR $*"; return 1; }

# ---------------- 基础读取 ----------------

get_mode() {
  M=""
  if [ -f "$MODEFILE" ]; then
    while IFS= read -r L || [ -n "$L" ]; do
      M=$L
      case "$M" in *[!\ ]*) break ;; esac
      M=""
    done < "$MODEFILE" 2>/dev/null
  fi
  M=${M%$CR}
  while :; do case "$M" in ' '*) M=${M#?} ;; *) break ;; esac; done
  while :; do case "$M" in *' ') M=${M%?} ;; *) break ;; esac; done
  case "$M" in sound|fast) echo "$M" ;; *) echo sound ;; esac
}

set_mode_file() {
  printf '%s\n' "$1" > "$MODEFILE.tmp" 2>/dev/null || return 1
  mv -f "$MODEFILE.tmp" "$MODEFILE" 2>/dev/null || return 1
  chmod 644 "$MODEFILE" 2>/dev/null
  return 0
}

applied_value() { cat "$STATE/applied" 2>/dev/null | tr -d ' \r\n'; }

# 探测调音模块提供的端口配置文件。
# 完全按文件名探测，不引用任何具体机型 / 模块名。
# 注意：不能用 set -f 关掉通配符展开（那样 glob 保持字面量、-f 恒假）；
# 未匹配时不同 shell 行为不同（字面量或展开为空），故用前缀判定区分。
detect_src() {
  [ -n "$SRC" ] && [ -f "$SRC" ] && return 0
  for _c in \
    /data/adb/modules/*/Link/odm/etc/audio/audio_module_config_primary.xml \
    /data/adb/modules/*/Link/vendor/etc/audio/audio_module_config_primary.xml \
    /data/adb/modules/*/odm/etc/audio/audio_module_config_primary.xml \
    /data/adb/modules/*/vendor/etc/audio/audio_module_config_primary.xml \
    /data/adb/modules/*/system/vendor/etc/audio/audio_module_config_primary.xml \
  ; do
    case "$_c" in
      *'*') continue ;;
      /data/adb/modules/*) [ -f "$_c" ] || continue ;;
      *) continue ;;
    esac
    SRC="$_c"
    return 0
  done
  return 1
}

# 从源路径推导设备上的生效路径：
#   <mod>/Link/odm/etc/... -> /odm/etc/...
#   <mod>/odm/etc/...      -> /odm/etc/...
# 即：剥掉 <mod>/ 前缀与可选的 Link/ 前缀，再补上 / 。
derive_target() {
  _r=${1#$MOD/}
  _r=${_r#Link/}
  case "$_r" in
    odm/*|vendor/*|system/*) TARGET="/$_r"; return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- 挂载所有权（证据，而非标记） ----------------

# 目标是否挂着**我们的**层：dev:ino 与 active.xml 相同
mount_is_ours() {
  [ -f "$TARGET" ] || return 1
  [ -f "$STATE/active.xml" ] || return 1
  _a=$(stat -c '%d:%i' "$STATE/active.xml" 2>/dev/null)
  _b=$(stat -c '%d:%i' "$TARGET" 2>/dev/null)
  [ -n "$_a" ] && [ "$_a" = "$_b" ]
}

# 目标当前是否挂载着（任意来源）
target_mounted() {
  [ -r /proc/self/mountinfo ] || return 1
  awk -v t="$TARGET" '$5==t {found=1; exit} END{exit !found}' /proc/self/mountinfo 2>/dev/null
}

# 摘掉我们的层。原先必须先确认这层是我们的，避免摘掉别人的挂载。
remove_our_mount() {
  [ -n "$TARGET" ] || return 0
  target_mounted || { rm -f "$STATE/owned" 2>/dev/null; return 0; }
  if mount_is_ours; then
    if umount "$TARGET" 2>/dev/null; then
      rm -f "$STATE/owned" 2>/dev/null
      return 0
    fi
    err unmount_failed_reboot_required; return 1
  fi
  # 挂着但内容不是我们的 —— 可能被别的模块替换了，绝不擅自动手
  err overlay_changed_by_another_module; return 1
}

# ---------------- 端口补丁（改副本 + 叠加挂载） ----------------

# 生成候选文件：从 base.xml 用 awk 摘标志，再与 base 比对确认确有变化
prepare_patch() {
  remove_fast_low="$1"; remove_fast_raw="$2"; remove_raw="$3"
  [ -f "$PATCHER" ] || { err patcher_missing; return 1; }
  [ -f "$STATE/base.xml" ] || { err baseline_missing; return 1; }

  awk -v remove_fast_low="$remove_fast_low" \
      -v remove_fast_raw="$remove_fast_raw" \
      -v remove_raw="$remove_raw" \
      -f "$PATCHER" "$STATE/base.xml" > "$STATE/candidate.xml" 2> "$STATE/patch-error.txt"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    _why=$(cat "$STATE/patch-error.txt" 2>/dev/null | head -1)
    rm -f "$STATE/candidate.xml"
    err "port_patch_rejected${_why:+_$_why}"
    return 1
  fi
  [ -s "$STATE/candidate.xml" ] || { err port_patch_empty; return 1; }
  if cmp -s "$STATE/base.xml" "$STATE/candidate.xml"; then
    rm -f "$STATE/candidate.xml"
    err no_port_changes
    return 1
  fi
  # 继承目标的属主与 SELinux 上下文，否则 audioserver 可能读不到
  chmod 0644 "$STATE/candidate.xml" 2>/dev/null
  chown 0:0 "$STATE/candidate.xml" 2>/dev/null
  _ctx=$(ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}')
  case "$_ctx" in u:object_r:*:s0*) chcon "$_ctx" "$STATE/candidate.xml" 2>/dev/null ;; esac
  mv -f "$STATE/candidate.xml" "$STATE/active.xml" || { err active_write_failed; return 1; }
  return 0
}

# 叠加挂载。**不 umount**：失败的 umount 会让该文件彻底失挂，比 mount 失败更糟。
install_patch() {
  touch "$STATE/owned" 2>/dev/null
  printf '%s\n' "$TARGET" > "$STATE/target" 2>/dev/null
  if ! mount --bind "$STATE/active.xml" "$TARGET" 2>/dev/null; then
    rm -f "$STATE/owned" 2>/dev/null
    err bind_mount_denied
    return 1
  fi
  if ! mount_is_ours; then
    err mount_not_visible
    return 1
  fi
  return 0
}

# 复核端口标志（读生效路径，而不是我们自己的文件）
verify_ports() {
  _want="$1"    # "nofast" | "fast"
  [ -f "$TARGET" ] || { err target_missing; return 1; }
  _low=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$TARGET" 2>/dev/null | head -1)
  _raw=$(sed -n 's/.*<mixPort name="raw_out"[^>]*flags="\([^"]*\)".*/\1/p' "$TARGET" 2>/dev/null | head -1)
  [ -n "$_low" ] || { err cannot_read_port_flags; return 1; }
  case "$_want" in
    nofast)
      case "$_low" in *FAST*) err low_latency_still_fast; return 1 ;; esac
      case "$_raw" in *FAST*) err raw_still_fast; return 1 ;; esac
      ;;
    fast)
      case "$_low" in *FAST*) ;; *) err low_latency_fast_missing; return 1 ;; esac
      ;;
  esac
  return 0
}

# ---------------- 守护进程 ----------------

daemon_running() { [ -n "$(pidof hyper-audio 2>/dev/null)" ]; }

start_daemon() {
  daemon_running && return 0
  if [ -f "$STARTER" ]; then
    setsid $SH "$STARTER" >/dev/null 2>&1 < /dev/null
  else
    [ -f "$DAEMON" ] || return 1
    chmod +x "$DAEMON" 2>/dev/null
    ( cd "$MOD" && setsid ./hyper-audio >> "$LOG" 2>&1 < /dev/null & )
  fi
  sleep 1
  _p=$(pidof hyper-audio 2>/dev/null | awk '{print $1}')
  [ -n "$_p" ] && printf '%s\n' "$_p" > "$PIDFILE"
  daemon_running
}

stop_daemon() {
  _p=$(cat "$PIDFILE" 2>/dev/null | tr -d ' \r\n')
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
  for _q in $(pidof hyper-audio 2>/dev/null); do kill "$_q" 2>/dev/null; done
  rm -f "$PIDFILE" 2>/dev/null
  return 0
}

# 音频服务无需重启时就不要动它：本机实测重启音频服务有让调音失效的风险，
# 因此只有端口标志**真的变了**才 killall。
restart_audio_only_if_needed() {
  [ "$1" = "1" ] || return 0
  killall audioserver 2>/dev/null
  return 0
}

# ---------------- 撤销到系统原始状态 ----------------

# 摘掉我们的挂载、删掉快照/标记。不碰任何第三方文件。
native_cleanup() {
  _fail=0
  remove_our_mount || _fail=1
  rm -f "$STATE/active.xml" "$STATE/candidate.xml" "$STATE/patch-error.txt" 2>/dev/null
  rm -f "$STATE/owned" 2>/dev/null
  [ "$_fail" = "0" ]
}

# ---------------- 兼容 0.4.5 的遗留改动 ----------------

# 0.4.5 及更早版本是**直接 sed 改调音模块源文件**的（不是改副本再 bind）。
# 因此从那些版本升级上来时，源文件可能已经缺少 FAST —— 那是旧版留下的补丁。
# 本模块不再那样做，但必须能把这个坑填掉，否则 FAST 永久缺失。
#
# 判据是保守的：只有源文件里两个端口**都**没有 FAST 时才认定为旧版遗留
# （调音模块正常提供的默认配置是带 FAST 的）。恢复后回读确认。
repair_legacy_source() {
  [ -n "$SRC" ] && [ -f "$SRC" ] || return 0
  _low=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$SRC" 2>/dev/null | head -1)
  _raw=$(sed -n 's/.*<mixPort name="raw_out"[^>]*flags="\([^"]*\)".*/\1/p' "$SRC" 2>/dev/null | head -1)
  [ -n "$_low" ] && [ -n "$_raw" ] || return 0
  _need=0
  case "$_low" in *FAST*) ;; *) _need=1 ;; esac
  case "$_raw" in *FAST*) ;; *) _need=1 ;; esac
  [ "$_need" = "1" ] || return 0

  log "repairing tuning source left patched by an older version of this module"
  sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$SRC" 2>/dev/null
  sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$SRC" 2>/dev/null
  chmod 644 "$SRC" 2>/dev/null

  # 回读确认；没修好就如实报错，不要让调用方以为已经干净
  _low=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$SRC" 2>/dev/null | head -1)
  case "$_low" in
    *FAST*) echo "legacy_repair=done"; return 0 ;;
    *)      echo "legacy_repair=failed"; return 1 ;;
  esac
}

# ---------------- 应用模式 ----------------

# 读取生效路径上 low_latency_out 是否带 FAST（用于判断改动前后是否真的不同）
read_fast_state() {
  [ -f "$TARGET" ] || { echo unknown; return; }
  _f=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$TARGET" 2>/dev/null | head -1)
  [ -n "$_f" ] || { echo unknown; return; }
  case "$_f" in *FAST*) echo yes ;; *) echo no ;; esac
}

apply_mode() {
  REQ="$1"
  case "$REQ" in sound|fast) ;; *) err bad_mode; return 1 ;; esac

  mkdir -p "$STATE" 2>/dev/null

  # 每次调用都从"未解析"开始，避免沿用上一次的 TARGET
  SRC=""
  TARGET=""

  # 需要补丁的是 sound；fast 只需要保证没有任何补丁
  NEED_PATCH=0
  [ "$REQ" = "sound" ] && NEED_PATCH=1

  if [ "$NEED_PATCH" = "1" ]; then
    detect_src || { err no_tuning_config; return 1; }
    [ -f "$SRC" ] || { err no_tuning_config; return 1; }
    derive_target "$SRC" || { err cannot_derive_target; return 1; }
    [ -f "$TARGET" ] || { err target_missing; return 1; }
    # 若源文件被旧版（<=0.4.5）直接改过，先把它恢复成原始形态，
    # 再以它为基线做补丁 —— 否则我们会把"缺 FAST"当成正常配置去摘标志。
    repair_legacy_source || { err legacy_source_repair_failed; return 1; }
  else
    # fast 也要知道目标在哪，才能确认补丁确实撤掉了
    if detect_src; then derive_target "$SRC" >/dev/null 2>&1 || TARGET=""; fi
  fi

  # 改动前的 FAST 状态（决定是否需要重启音频服务）
  BEFORE_FAST=$(read_fast_state)

  # 先摘掉旧的层：无论哪种模式，都要从干净状态开始
  remove_our_mount || return 1

  if [ "$NEED_PATCH" = "1" ]; then
    # 重新快照：调音模块可能在这期间被更新过
    cp -f "$TARGET" "$STATE/base.xml" 2>/dev/null || { err snapshot_failed; return 1; }
    AFTER_FAST=$(read_fast_state)
    prepare_patch 1 1 1 || return 1
    install_patch || return 1
    verify_ports nofast || return 1
  else
    # fast：撤销补丁后必须确认端口回到带 FAST 的原始配置
    if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
      verify_ports fast || return 1
      AFTER_FAST=$(read_fast_state)
    else
      AFTER_FAST=""
    fi
  fi

  # 只有端口标志真的不同才需要重启音频服务
  b=${BEFORE_FAST:-}
  a=${AFTER_FAST:-}
  if [ -n "$b" ] && [ -n "$a" ] && [ "$b" != "unknown" ] && [ "$a" != "unknown" ] && [ "$b" != "$a" ]; then
    FLAGS_CHANGE=1
  else
    FLAGS_CHANGE=0
  fi
  return 0
}

# ---------------- 事务外壳 ----------------

do_apply() {
  REQ="$1"
  case "$REQ" in sound|fast) ;; *) err bad_mode; return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null

  PREV_APPLIED=$(applied_value)
  PREV_MODE=$(get_mode)

  # 事务标记：中途被杀 / 重启都能被下一次开机发现
  printf '%s\n' "$REQ" > "$STATE/pending" 2>/dev/null || return 1

  apply_mode "$REQ"
  RC=$?

  if [ "$RC" -ne 0 ]; then
    log "apply $REQ failed (rc=$RC); rolling back to native"
    # 回滚：撤销我们的一切改动，并把 mode 写回 native，
    # 避免"mode 文件说 sound、实际却是原始配置"的不一致。
    if native_cleanup; then
      set_mode_file fast || log "cannot write mode during rollback"
      printf 'native\n' > "$STATE/applied" 2>/dev/null
      rm -f "$STATE/pending" 2>/dev/null
      update_desc
      err apply_failed_restored_native
    else
      set_mode_file fast
      printf 'native\n' > "$STATE/applied" 2>/dev/null
      err rollback_incomplete_reboot_required
    fi
    return 1
  fi

  # 端口标志真的变了才重启音频服务
  restart_audio_only_if_needed "$FLAGS_CHANGE"

  DAEMON_OK=1
  if [ "$REQ" = "sound" ]; then
    stop_daemon
  else
    start_daemon || DAEMON_OK=0
  fi

  printf '%s\n' "$REQ" > "$STATE/applied" 2>/dev/null
  rm -f "$STATE/pending" 2>/dev/null
  set_mode_file "$REQ" || { err cannot_save_mode; return 1; }
  rm -f "$STATE/boot.failure" 2>/dev/null
  update_desc

  echo "ok=1"
  echo "mode=$REQ"
  [ "$DAEMON_OK" = "1" ] || echo "warn=daemon_not_running"
  [ "$NEED_PATCH" = "1" ] && echo "verified=1"
  echo "flags_changed=$FLAGS_CHANGE"
  return 0
}

# ---------------- 开机与护栏 ----------------

boot_current() { cat "$STATE/boot" 2>/dev/null | tr -d ' \r\n'; }

set_boot_current() {
  printf '%s\n' "$1" > "$STATE/boot.tmp" 2>/dev/null && mv -f "$STATE/boot.tmp" "$STATE/boot" 2>/dev/null
}

# 开机护栏原因只认白名单；未知内容降级为 previous_failure，避免被畸形内容左右
guard_reason() {
  case "$1" in
    interrupted_startup_or_transition|apply_previous_failed|unmount_failed|overlay_changed|previous_failure) echo "$1" ;;
    '') echo none ;;
    *) echo previous_failure ;;
  esac
}

boot_run() {
  mkdir -p "$STATE" 2>/dev/null
  BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$BOOT_ID" ] || { err cannot_read_boot_id; return 1; }

  # 去重：同一次启动只执行一次
  if [ "$(boot_current)" = "$BOOT_ID" ]; then
    log "boot handler already ran for this boot"
    return 0
  fi
  set_boot_current "$BOOT_ID"

  # 上次没跑完或上次切换失败 => 护栏：本次强制 native，且不自动重试
  REASON=none
  if [ -f "$STATE/pending" ]; then
    REASON=interrupted_startup_or_transition
  elif [ -f "$STATE/boot.failure" ]; then
    REASON=$(guard_reason "$(cat "$STATE/boot.failure" 2>/dev/null | head -1)")
    [ "$REASON" = none ] && REASON=previous_failure
  fi

  if [ "$REASON" != "none" ]; then
    log "boot guard active: $REASON -> forcing native"
    # 清掉可能残留的层，保证这次开机一定是原始配置
    native_cleanup
    set_mode_file fast
    printf 'native\n' > "$STATE/applied" 2>/dev/null
    rm -f "$STATE/pending" 2>/dev/null
    printf '%s\n' "$REASON" > "$STATE/boot.failure" 2>/dev/null
    update_desc
    echo "guard=$REASON"
    echo "mode=native"
    return 1
  fi

  # 正常路径：按 mode 文件应用
  M=$(get_mode)
  do_apply "$M"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    printf '%s\n' apply_previous_failed > "$STATE/boot.failure" 2>/dev/null
    log "boot apply failed; guard recorded"
    return 1
  fi
  echo "mode=$M"
  return 0
}

# ---------------- 恢复 ----------------

recover() {
  mkdir -p "$STATE" 2>/dev/null
  stop_daemon
  native_cleanup || { err recover_incomplete_reboot_required; return 1; }
  set_mode_file fast
  printf 'native\n' > "$STATE/applied" 2>/dev/null
  rm -f "$STATE/pending" "$STATE/boot.failure" 2>/dev/null
  update_desc
  echo "ok=1"
  echo "mode=native"
  return 0
}

# ---------------- module.prop 模式前缀 ----------------

# 剥掉已有的「【…】」前缀（逐层剥）。
# 不能用 sed 's/^【[^】]*】//'：多字节 [^】] 会被按字节处理，
# 从第一个【 一直匹配到最后一个】，整行匹配后又替换回原样 ——
# 表现为"没剥"，前缀层层叠加（已在设备上复现）。
update_desc() {
  [ -f "$MODPROP" ] || return 0
  MS=$(sed -n 's/^mode\.sound=//p' "$MODPROP" | head -1)
  MF=$(sed -n 's/^mode\.fast=//p'  "$MODPROP" | head -1)
  [ -n "$MS" ] || MS='音效模式'
  [ -n "$MF" ] || MF='低延迟模式'

  M=$(get_mode)
  if [ "$M" = "fast" ]; then TAG="$MF"; else TAG="$MS"; fi

  ORIG=$(sed -n 's/^description=//p' "$MODPROP")
  while :; do
    case "$ORIG" in
      【*) ORIG="${ORIG#*】}" ;;
      *) break ;;
    esac
  done

  TMP=$STATE/prop.$$
  {
    grep -v '^description=' "$MODPROP" | grep -v '^credits=' | grep -v '^mode\.'
    printf 'description=【当前模式：%s】%s\n' "$TAG" "$ORIG"
    grep '^credits=' "$MODPROP" 2>/dev/null
    printf 'mode.sound=%s\n' "$MS"
    printf 'mode.fast=%s\n'  "$MF"
  } > "$TMP" 2>/dev/null

  if [ -s "$TMP" ] && grep -q '^id=' "$TMP" && grep -q '^description=' "$TMP"; then
    cat "$TMP" > "$MODPROP"
    chmod 644 "$MODPROP" 2>/dev/null
  fi
  rm -f "$TMP" 2>/dev/null
}

# ---------------- 状态 ----------------

do_status() {
  echo "requested=$(get_mode)"
  echo "applied=$(applied_value)"
  echo "pending=$([ -f "$STATE/pending" ] && echo yes || echo no)"
  if [ -f "$STATE/boot.failure" ]; then echo "boot_guard=$(cat "$STATE/boot.failure" 2>/dev/null | head -1)"; else echo "boot_guard=none"; fi
  if daemon_running; then echo "daemon=running"; else echo "daemon=stopped"; fi
  detect_src >/dev/null 2>&1 && echo "source=$SRC" || echo "source=none"
  if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
    echo "target=$TARGET"
    if mount_is_ours; then echo "overlay=ours"
    elif target_mounted; then echo "overlay=conflict"
    else echo "overlay=none"; fi
    sed -n 's/.*<mixPort name="\(low_latency_out\|raw_out\)"[^>]*flags="\([^"]*\)".*/port=\1 flags=\2/p' "$TARGET" 2>/dev/null
  else
    echo "target=missing"
    echo "overlay=none"
  fi
}

# ---------------- 入口 ----------------

case "$1" in
  apply)
    do_apply "$2"
    exit $?
    ;;
  current) get_mode ;;
  boot)    boot_run ;;
  recover) recover ;;
  desc)    update_desc; sed -n 's/^description=//p' "$MODPROP" 2>/dev/null | cut -c1-40 ;;
  status)  do_status ;;
  *) echo "usage: runtime.sh {apply <sound|fast>|current|boot|recover|status|desc}"; exit 1 ;;
esac
