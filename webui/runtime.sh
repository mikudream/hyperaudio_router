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

# 路径。HA_MOD / HA_TMP / HA_SOURCE_DIR / HA_MOUNTINFO 只是为了让主机侧测试
# 能把整棵树重定向到临时目录，真机上不设这些变量，取值与原来完全一致。
MOD=${HA_MOD:-/data/adb/modules/hyperaudio}
STATE=$MOD/state
MODEFILE=$MOD/mode
MODPROP=$MOD/module.prop
TMP=${HA_TMP:-/data/local/tmp}
PIDFILE=$TMP/hyperaudio.pid
DAEMON=$MOD/hyper-audio
STARTER=$MOD/bin/start_daemon.sh
PATCHER=$MOD/bin/patch_ports.awk
LOG=$TMP/hyper-audio.log
RUNTIME_LOG=$TMP/hyperaudio-runtime.log
SH=${HA_SH:-/system/bin/sh}
MOUNTINFO=${HA_MOUNTINFO:-/proc/self/mountinfo}
BOOT_ID_FILE=${HA_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
SOURCE_DIR=${HA_SOURCE_DIR:-/data/adb/modules}
CR=$(printf '\r')

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$RUNTIME_LOG" 2>/dev/null; }
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
    $SOURCE_DIR/*/Link/odm/etc/audio/audio_module_config_primary.xml \
    $SOURCE_DIR/*/Link/vendor/etc/audio/audio_module_config_primary.xml \
    $SOURCE_DIR/*/odm/etc/audio/audio_module_config_primary.xml \
    $SOURCE_DIR/*/vendor/etc/audio/audio_module_config_primary.xml \
    $SOURCE_DIR/*/system/vendor/etc/audio/audio_module_config_primary.xml \
  ; do
    case "$_c" in
      *'*') continue ;;
      $SOURCE_DIR/*) [ -f "$_c" ] || continue ;;
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
# 即：剥掉源根目录（默认 /data/adb/modules，可用 HA_SOURCE_DIR 重定向）
# 与模块目录名，再剥掉可选的 Link/，最后补上 / 。
#
# 注意这里剥的是 $SOURCE_DIR 而不是 $MOD —— 探测出来的源文件位于**别的**
# 模块目录下，用 $MOD 去剥在真机上恰好也能匹配上（因为两者同属
# /data/adb/modules 子树），但那是巧合；主机侧注入测试就会暴露成
# cannot_derive_target。
derive_target() {
  _r=${1#$SOURCE_DIR/}
  _r=${_r#*/}
  _r=${_r#Link/}
  case "$_r" in
    odm/*|vendor/*|system/*)
      # HA_TARGET_BASE 只为主机侧测试把绝对目标根重定向到临时目录；
      # 真机不设，取值就是空串，TARGET 与原来的 "/$_r" 完全一致。
      TARGET="${HA_TARGET_BASE:-}/$_r"
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- 挂载所有权（证据，而非标记） ----------------

# 目标是否挂着**我们的**层。判据（按可靠性排序）：
#   1) dev:ino 与 state/active.xml 相同 —— 内容级证据
#   2) 退路：如果拿不到 dev:ino（某些 toybox/f2fs 组合下 stat 可能不给），
#      再看 mountinfo 里该挂载是否确实覆盖了目标，且目标内容与 active.xml 一致
mount_is_ours() {
  # 测试钩子：主机侧无法建立真实的 bind mount，dev:ino 证据也不成立。
  # 生产环境不设这两个变量，全部走下面的真实判据。
  # 见 tests/test_runtime_state_machine.sh。
  case "${HA_RT_OURS_TEST:-}" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac

  [ -f "$TARGET" ] || return 1
  [ -f "$STATE/active.xml" ] || return 1

  # 比对对象：真机就是目标文件本身；HA_RT_TARGET_STAT 仅在测试里指向一个
  # 被挂载系统调用覆盖过的路径（bind mount 会产生这一层）。
  _t=${HA_RT_TARGET_STAT:-$TARGET}
  _a=$(stat -c '%d:%i' "$STATE/active.xml" 2>/dev/null)
  _b=$(stat -c '%d:%i' "$_t" 2>/dev/null)
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then return 0; fi

  # 退路只在确实挂着、且字节一致时才认，避免把"恰好同内容"当成我们的层
  target_mounted || return 1
  cmp -s "$STATE/active.xml" "$TARGET" 2>/dev/null
}

# 目标当前是否挂载着（任意来源）
target_mounted() {
  [ -r "$MOUNTINFO" ] || return 1
  awk -v t="$TARGET" '$5==t {found=1; exit} END{exit !found}' "$MOUNTINFO" 2>/dev/null
}

# 生效路径是否仍是调音模块的**原始**文件（没有别的补丁层压在上面）。
# 判据：生效路径与调音模块源文件是同一个 inode。
#
# 这条判据是"能不能安全覆盖"的本质依据：只要它成立，压在我们下面的就是
# 调音模块自己的那份，我们叠一层再摘掉不会有任何损失。
# 反过来，如果路径上已经压着别人的补丁，inode 就对不上，绝不能动。
target_is_pristine() {
  [ -n "$TARGET" ] && [ -n "$SRC" ] || return 1
  [ -f "$TARGET" ] && [ -f "$SRC" ] || return 1
  _ta=$(stat -c '%d:%i' "$TARGET" 2>/dev/null)
  _sa=$(stat -c '%d:%i' "$SRC" 2>/dev/null)
  [ -n "$_ta" ] && [ "$_ta" = "$_sa" ]
}

# 启动时把 TARGET 解析出来（TARGET 原先只在 apply_mode 里推导）。
resolve_target() {
  if [ -f "$STATE/target" ]; then
    TARGET=$(head -1 "$STATE/target" 2>/dev/null | tr -d ' \r\n')
    [ -n "$TARGET" ] && return 0
  fi
  # 回退：按调音模块源文件重新推导，这样"只有 state 丢了"的情况也能收尾
  SRC=""
  detect_src || { TARGET=""; return 1; }
  derive_target "$SRC" || { TARGET=""; return 1; }
  return 0
}

# 摘掉我们的层。必须先确认这层是我们的，避免摘掉别人的挂载。
#
# 注意：这里**不能**在 TARGET 为空时就直接 return 0。原先就是这么写的，而
# TARGET 只在 apply_mode 里推导 —— 于是 recover（以及走 recover 的卸载清理）
# 在"当前模式是 fast"时压根不会去摘挂载，却照样报 ok=1。主机侧注入测试
# 定位到了这一点（test 9）。
remove_our_mount() {
  resolve_target
  [ -n "$TARGET" ] || return 0

  # 我们从未建立过层（没有 active.xml 也没有 owned 标记）时，目标上挂着的
  # 必然是**别的模块**的层 —— 这是正常情况，不是冲突。
  # 真机上踩到过：首次开机时 /odm 上挂着调音模块自己的 bind mount，
  # mount_is_ours 因为没有 active.xml 可比而返回假，于是被误判成
  # overlay_changed_by_another_module，触发回滚 + 开机护栏，
  # 结果模块一装上就被自己锁在原生模式。
  if [ ! -f "$STATE/active.xml" ] && [ ! -f "$STATE/owned" ]; then
    return 0
  fi

  target_mounted || { rm -f "$STATE/owned" "$STATE/active.xml" "$STATE/target" 2>/dev/null; return 0; }
  if mount_is_ours; then
    if umount "$TARGET" 2>/dev/null; then
      # 摘层成功就把自己的痕迹清干净：active.xml 留着会让下一次
      # mount_is_ours 拿它去和"现在挂着的那层"（比如调音模块自己的）比对，
      # 从而误报 overlay_changed_by_another_module，把后续 apply 也一起挡掉。
      # 真机上就是这样：fast -> sound -> fast 之后再也切不回 sound。
      rm -f "$STATE/owned" "$STATE/active.xml" "$STATE/target" 2>/dev/null
      return 0
    fi
    err unmount_failed_reboot_required; return 1
  fi

  # 不是我们的层，但如果生效路径仍是调音模块的原始文件，说明压在我们下面的
  # 就是它自己的那份 —— 这在首次使用、或上次摘层后残留旧 active.xml 时都会
  # 出现，是正常情况，不是冲突。直接清掉自己的痕迹，让调用方重新叠加。
  if target_is_pristine; then
    rm -f "$STATE/owned" "$STATE/active.xml" "$STATE/target" 2>/dev/null
    return 0
  fi

  # 既不是我们的层、下面也不是原始文件 —— 有第三方补丁压着，绝不擅自动手
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
# 因此只有端口标志**真的变了**才重启。
#
# 但"重启了"不等于"配置生效了"：服务要先读策略、建主输出、填 HAL 缓冲。
# 所以重启后必须验证框架真的就绪（见 bin/audio_ready.sh），
# 这也是 0.4.7 相对 0.4.6 最重要的改进 —— 原先只看磁盘文件内容。
#
# 返回值语义：
#   0  已就绪（AUDIO_READY=passed）或无法验证但不算故障（AUDIO_READY=unverified）
#   1  被证伪（AUDIO_READY=failed），调用方应回滚
restart_audio_checked() {
  _mode=$1
  _old=$(pidof audioserver 2>/dev/null)
  if [ -z "$_old" ]; then
    AUDIO_READY=failed
    err audioserver_not_running
    return 1
  fi

  # 沿用本模块既有的 killall（不用 setprop ctl.restart：实测那条路有让调音失效的风险）
  killall audioserver 2>/dev/null
  audio_wait_ready "$_mode" "$_old"
  if [ $? -eq 0 ]; then
    AUDIO_READY=passed
    return 0
  fi

  _why=$(audio_ready_reason)
  AUDIO_READY=unverified
  if audio_ready_is_fatal "$_why"; then
    AUDIO_READY=failed
    err "audio_not_ready_${_why:-unknown}"
    return 1
  fi
  # 读不到 / 格式不认 / 等超时：不算故障，但绝不宣称已验证
  log "audio readiness unverified ($_why); keeping mode"
  echo "warn=audio_unverified_${_why:-unknown}"
  return 0
}

# ---------------- 撤销到系统原始状态 ----------------

# 摘掉我们的挂载、删掉快照/标记。不碰任何第三方文件。
native_cleanup() {
  _fail=0
  resolve_target
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
    # 只摘 FAST（两个端口），**保留 raw_out 的 RAW**：
    #   · 与本文件开头声明的语义一致（"摘掉 FAST 标志"），也与 0.4.5 的 sed 行为一致
    #     （0.4.5 是 "FAST RAW" -> "RAW"）
    #   · 摘掉 RAW 会让 raw_out 一个标志都不剩，端口退化成无标志状态，
    #     风险不明（audio policy 可能不接受），而收益只是多影响"显式请求 raw 输出"的应用
    # 注：0.4.6 曾误传第三个参数为 1（连 RAW 一起摘），0.4.7 起修正为只摘 FAST。
    prepare_patch 1 1 0 || return 1
    install_patch || return 1
    verify_ports nofast || return 1
    # AFTER_FAST 必须在**补丁装好之后**读。
    # 0.4.6 把它读在 install_patch 之前，于是 fast->sound 永远判成"标志没变"
    # 而不重启音频服务 —— 结果配置写了却没被加载，等于没切。
    AFTER_FAST=$(read_fast_state)
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

# 回滚到系统原始配置。失败路径统一走这里，避免两处逻辑不一致。
rollback_to_native() {
  log "rolling back to native"
  if native_cleanup; then
    set_mode_file fast || log "cannot write mode during rollback"
    printf 'native\n' > "$STATE/applied" 2>/dev/null
    rm -f "$STATE/pending" 2>/dev/null
    update_desc
    return 0
  fi
  set_mode_file fast
  printf 'native\n' > "$STATE/applied" 2>/dev/null
  return 1
}

do_apply() {
  REQ="$1"
  case "$REQ" in sound|fast) ;; *) err bad_mode; return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null

  # BOOT_ID 在手动切换时可能还没算过；就绪记录要按 boot 归属，这里补上
  if [ -z "$BOOT_ID" ]; then BOOT_ID=$(cat "$BOOT_ID_FILE" 2>/dev/null); fi
  [ -n "$BOOT_ID" ] || BOOT_ID=unknown-boot

  PREV_APPLIED=$(applied_value)
  PREV_MODE=$(get_mode)

  # 事务标记：中途被杀 / 重启都能被下一次开机发现
  printf '%s\n' "$REQ" > "$STATE/pending" 2>/dev/null || return 1

  AUDIO_READY=""
  apply_mode "$REQ"
  RC=$?

  if [ "$RC" -ne 0 ]; then
    log "apply $REQ failed (rc=$RC); rolling back to native"
    # 回滚：撤销我们的一切改动，并把 mode 写回 native，
    # 避免"mode 文件说 sound、实际却是原始配置"的不一致。
    if rollback_to_native; then
      err apply_failed_restored_native
    else
      err rollback_incomplete_reboot_required
    fi
    return 1
  fi

  # 端口标志真的变了才重启音频服务；重启后必须确认框架真的加载了新配置。
  if [ "$FLAGS_CHANGE" = "1" ]; then
    if ! restart_audio_checked "$REQ"; then
      # 被证伪（加载的 flags 与我们写的不符 / 服务起不来）：这是真的故障，回滚
      log "audio readiness was disproved (reason=$(audio_ready_reason)); rolling back"
      if rollback_to_native; then
        err apply_failed_restored_native
      else
        err rollback_incomplete_reboot_required
      fi
      return 1
    fi
  else
    # 没有重启：沿用上一次的记录（可能是 passed，也可能是 stale）
    AUDIO_READY=$(audio_ready_state)
  fi

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

  # verified=1 现在表示：文件级（/odm 内容）与框架级（audioserver 实际加载）
  # **两重**都通过。只看到文件对不再算验证通过 —— 这是我们与 0.4.6 的差别。
  if [ "$AUDIO_READY" = "passed" ] && { [ "$REQ" = "fast" ] || [ "$NEED_PATCH" = "1" ]; }; then
    echo "verified=1"
  else
    echo "verified=0"
  fi
  echo "audio_ready=${AUDIO_READY:-unverified}"
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
  BOOT_ID=$(cat "$BOOT_ID_FILE" 2>/dev/null)
  # 兜底：极少数环境读不到 boot_id（文件缺失/权限）。用固定值总比整个开机
  # 逻辑罢工好 —— 去重语义会弱化成"只跑一次"，但仍能应用模式。
  [ -n "$BOOT_ID" ] || BOOT_ID=unknown-boot
  log "boot_run: boot_id=$BOOT_ID"

  # 去重：同一次启动只执行一次
  if [ "$(boot_current)" = "$BOOT_ID" ]; then
    log "boot handler already ran for this boot"
    # 明确回一行：调用方（service.sh / 诊断）需要能区分"已跑过"和"跑失败了"
    echo "already_ran=1"
    echo "mode=$(get_mode)"
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
  resolve_target
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
  # 音频框架是否真的加载了当前配置（见 bin/audio_ready.sh）
  if [ -z "$BOOT_ID" ]; then BOOT_ID=$(cat "$BOOT_ID_FILE" 2>/dev/null); fi
  [ -n "$BOOT_ID" ] || BOOT_ID=unknown-boot
  audio_ready_status
}

# ---------------- 入口 ----------------

# audio_ready.sh 依赖 log/err 与上方变量，放在入口之前载入。
# 若它缺失（例如只更新了部分文件的中间状态），降级为"不校验"而不是让整个
# 模式切换失败 —— 切换本身是核心功能，就绪校验只是附加证据。
if [ -f "$MOD/bin/audio_ready.sh" ]; then
  . "$MOD/bin/audio_ready.sh"
else
  log "audio_ready.sh missing; readiness verification disabled"
  audio_wait_ready()    { return 1; }
  audio_ready_reason()  { echo ready_helper_missing; }
  audio_ready_is_fatal() { return 1; }
  audio_ready_state()   { echo unverified; }
  audio_ready_status()  {
    echo "audio_ready=unverified"
    echo "audio_ready_reason=ready_helper_missing"
  }
fi

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
