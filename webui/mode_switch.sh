#!/system/bin/sh
# ============================================================
# hyperaudio — 音效 / 低延迟 模式切换
# ============================================================
# 模式语义：
#   sound（音效模式，默认）
#     · 摘掉 low_latency_out / raw_out 的 FAST 标志 → 所有应用音频落入
#       普通混音线程（效果链），Dolby 调音 / 按应用档案得以生效
#     · 停止 hyper-audio 守护进程（音效模式下不需要 RT 提权）
#   fast（低延迟模式）
#     · 恢复 FAST 标志 → 应用走 fast track（FastMixer），延迟最低
#     · 启动 hyper-audio 守护进程，并给音频线程提 RT 优先级
#
# 实现要点：
#   改的是外部调音模块提供的 audio_module_config_primary.xml（模块内的源文件，
#   位于可写的模块目录里），改完重新 bind mount 到 /odm 生效。
#   /odm 本身只读，无法直接在其上 sed -i。
#   源文件位置由 detect_src() 按文件名自动探测，不绑定任何具体机型 / 模块名。
#
# 用法: sh mode_switch.sh apply <sound|fast>
#       sh mode_switch.sh current
#       sh mode_switch.sh status
# ============================================================

MOD=/data/adb/modules/hyperaudio
MODEFILE=$MOD/mode
MODPROP=$MOD/module.prop
PIDFILE=/data/local/tmp/hyperaudio.pid
DST=/odm/etc/audio/audio_module_config_primary.xml
# 端口配置由外部调音模块提供，运行时由 detect_src() 自动探测，不硬编码模块名。
SRC=""
DAEMON=$MOD/hyper-audio
STARTER=$MOD/bin/start_daemon.sh
LOG=/data/local/tmp/hyper-audio.log

CR=$(printf '\r')
SH=/system/bin/sh

get_mode() {
  M=""
  if [ -f "$MODEFILE" ]; then
    while IFS= read -r L || [ -n "$L" ]; do
      M=$L
      case "$M" in *[!\ ]*) break ;; esac
      M=""
    done < "$MODEFILE" 2>/dev/null
  fi
  while :; do case "$M" in ' '*) M=${M#?} ;; *) break ;; esac; done
  while :; do case "$M" in *' ') M=${M%?} ;; *"$CR") M=${M%?} ;; *) break ;; esac; done
  case "$M" in sound|fast) echo "$M" ;; *) echo sound ;; esac
}

# 找到提供 audio_module_config_primary.xml 的调音模块源文件。
# 完全按文件名探测，不引用任何具体机型的模块名 —— 任何调音模块，只要把该文件
# 放在下面几种布局之一，都能被找到。
#
# 注意：这里【不能】用 set -f 关掉通配符展开 —— 那样 glob 会保持字面量，
# 下面的 -f 判定永远为假（实测踩过）。反过来，不同 shell 对"glob 无匹配"的
# 行为也不同（有的保持字面量、有的展开为空），所以用前缀判定区分：
# 只有真正展开成 /data/... 的才算候选路径。
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
      *'*') continue ;;                          # 仍含通配符 => 未展开，跳过
      /data/adb/modules/*) [ -f "$_c" ] || continue ;;
      *) continue ;;
    esac
    SRC="$_c"
    return 0
  done
  return 1
}

# 守护进程是否在运行：pidof 最可靠（pgrep -f 与 PID 文件在本设备上都不稳）
daemon_running() {
  [ -n "$(pidof hyper-audio 2>/dev/null)" ]
}

# 启动守护进程；返回真实结果（原先无条件 return 0，失败也会被当成功）
start_daemon() {
  daemon_running && return 0
  # 用独立启动器 + setsid：确保守护进程完全脱离本脚本，
  # 否则本脚本退出（或 killall audioserver）时会把同会话的子进程一起带走。
  # 用 -f 而非 -x：安装后脚本可能没有执行位（见 helper.sh 的说明）。
  if [ -f "$STARTER" ]; then
    setsid $SH "$STARTER" >/dev/null 2>&1 < /dev/null
  else
    [ -f "$DAEMON" ] || return 1
    chmod +x "$DAEMON" 2>/dev/null
    ( cd "$MOD" && setsid ./hyper-audio >> "$LOG" 2>&1 < /dev/null & )
  fi
  sleep 1
  P=$(pidof hyper-audio 2>/dev/null | awk '{print $1}')
  [ -n "$P" ] && printf '%s\n' "$P" > "$PIDFILE"
  daemon_running
}

stop_daemon() {
  P=$(cat "$PIDFILE" 2>/dev/null | tr -d ' \r\n')
  [ -n "$P" ] && kill "$P" 2>/dev/null
  for q in $(pidof hyper-audio 2>/dev/null); do kill "$q" 2>/dev/null; done
  rm -f "$PIDFILE" 2>/dev/null
  return 0
}

apply_flags() {
  M="$1"
  detect_src || { echo "error=no_tuning_config"; return 1; }
  [ -f "$SRC" ] || { echo "error=no_tuning_config"; return 1; }
  [ -f "$DST" ] || { echo "error=target_missing"; return 1; }

  BAK=/data/local/tmp/amcp.before_switch
  cp -f "$SRC" "$BAK" 2>/dev/null || { echo "error=backup_failed"; return 1; }

  if [ "$M" = "sound" ]; then
    sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)FAST PRIMARY">|\1PRIMARY">|' "$SRC"
    s1=$?
    sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)FAST RAW">|\1RAW">|' "$SRC"
    s2=$?
    WANT="PRIMARY"
  else
    sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$SRC"
    s1=$?
    sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$SRC"
    s2=$?
    WANT="FAST PRIMARY"
  fi
  chmod 644 "$SRC" 2>/dev/null

  # sed 本身失败即回滚（原先完全不检查返回码，补丁失败也报成功）
  if [ "$s1" != "0" ] || [ "$s2" != "0" ]; then
    cp -f "$BAK" "$SRC" 2>/dev/null
    echo "error=sed_failed"
    return 1
  fi

  # 复核目标标志。若关键 mixPort 根本不存在，则无法判断 —— 这时按"未验证但继续"
  # 处理并明确告知（UNVERIFIED），而不是谎报成功。
  UNVERIFIED=0
  if grep -q 'mixPort name="low_latency_out"' "$SRC" 2>/dev/null; then
    if grep -q "mixPort name=\"low_latency_out\"[^>]*flags=\"$WANT\"" "$SRC" 2>/dev/null; then
      :
    else
      cp -f "$BAK" "$SRC" 2>/dev/null
      echo "error=flag_patch_failed"
      return 1
    fi
  else
    UNVERIFIED=1
  fi

  # 重新 bind mount 到 /odm
  umount "$DST" 2>/dev/null
  if ! mount --bind "$SRC" "$DST" 2>/dev/null; then
    # 挂载失败：此时 /odm 上原本由调音模块建立的挂载已被 umount 摘掉，
    # 必须尽力恢复，否则 audioserver 重启后可能直接没声音。
    mount --bind "$BAK" "$DST" 2>/dev/null || mount --bind "$SRC" "$DST" 2>/dev/null
    echo "error=mount_failed"
    return 1
  fi
  restorecon "$DST" 2>/dev/null
  rm -f "$BAK" 2>/dev/null
  return 0
}

# 把当前模式写进 module.prop 的 description，供 KernelSU / Magisk 模块列表直接显示。
# description 是任意文本，管理器把原始字节照原样渲染，所以用一个「当前模式」标记做前缀。
#
# 标记文字优先取自 module.prop 自身的 mode.sound / mode.fast 行，这样反复切换
# 都是读回同一份定义，不会在脚本里另写一份；若标记尚未建立则用下面的默认值。
# 每次更新都先把已有标记剥掉，避免反复切换后层层叠加。
# module.prop 不会被挂载进系统分区，因此运行时改写是持久的。
update_desc() {
  [ -f "$MODPROP" ] || return 0

  # 标记定义存放于 module.prop 的 mode.* 行
  MS=$(sed -n 's/^mode\.sound=//p' "$MODPROP" | head -1)
  MF=$(sed -n 's/^mode\.fast=//p'  "$MODPROP" | head -1)
  [ -n "$MS" ] || MS='音效模式'
  [ -n "$MF" ] || MF='低延迟模式'

  M=$(get_mode)
  if [ "$M" = "fast" ]; then TAG="$MF"; else TAG="$MS"; fi

  # 去掉已有的「【当前模式：…】」前缀（前缀内不含右括号字符）
  ORIG=$(sed -n 's/^description=//p' "$MODPROP" \
    | sed 's/^【[^】]*】//')

  TMP=/data/local/tmp/hyperaudio.prop.$$
  {
    # 保留 id/name/version/versionCode/author 等，丢掉旧的 description / credits
    # 以及上一轮的 mode.* 标记行（稍后统一补回）
    grep -v '^description=' "$MODPROP" | grep -v '^credits=' | grep -v '^mode\.'
    printf 'description=【当前模式：%s】%s\n' "$TAG" "$ORIG"
    grep '^credits=' "$MODPROP" 2>/dev/null
    printf 'mode.sound=%s\n' "$MS"
    printf 'mode.fast=%s\n'  "$MF"
  } > "$TMP" 2>/dev/null

  # 只在写入成功且内容合理时替换，避免把 module.prop 写坏
  if [ -s "$TMP" ] && grep -q '^id=' "$TMP" && grep -q '^description=' "$TMP"; then
    cat "$TMP" > "$MODPROP"
    chmod 644 "$MODPROP" 2>/dev/null
  fi
  rm -f "$TMP" 2>/dev/null
}

case "$1" in
  apply)
    M="$2"
    case "$M" in sound|fast) ;; *) echo "error=bad_mode"; exit 1 ;; esac

    # 先打补丁 / 挂载。只有成功后才写 mode 文件 —— 否则会出现
    # "mode 文件已改成目标值、但端口标志没变"的不一致状态
    # （开机逻辑以 mode 文件为准，界面与实际就会互相矛盾）。
    # 注意：不能写成 `ERR=$(f); if [ $? ... ]` —— 那样 $? 取的是赋值语句的结果。
    UNVERIFIED=0
    OUT=/data/local/tmp/ms.out
    apply_flags "$M" > "$OUT" 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
      # apply_flags 已把 SRC 回滚到切换前的内容
      cat "$OUT" 2>/dev/null
      rm -f "$OUT"
      exit 1
    fi
    rm -f "$OUT"

    printf '%s\n' "$M" > "$MODEFILE" 2>/dev/null
    chmod 644 "$MODEFILE" 2>/dev/null

    DAEMON_OK=1
    if [ "$M" = "sound" ]; then
      stop_daemon
    else
      start_daemon || DAEMON_OK=0
    fi
    killall audioserver 2>/dev/null
    update_desc

    echo "ok=1"
    echo "mode=$M"
    # 让调用方能区分"完全成功"与"端口已切但守护进程没起来"
    [ "$DAEMON_OK" = "1" ] || echo "warn=daemon_not_running"
    [ "$UNVERIFIED" = "1" ] || echo "verified=1"
    exit 0
    ;;

  current)
    get_mode
    ;;

  # 只刷新 module.prop 的「当前模式」前缀，不切换模式（供开机与 WebUI 调用）
  desc)
    update_desc
    sed -n 's/^description=//p' "$MODPROP" 2>/dev/null | cut -c1-40
    ;;

  status)
    M=$(get_mode)
    echo "mode=$M"
    if daemon_running; then echo "daemon=running"; else echo "daemon=stopped"; fi
    echo "target=$([ -f "$DST" ] && echo exists || echo missing)"
    [ -f "$SRC" ] && grep -E 'mixPort name="(low_latency_out|raw_out)"' "$SRC"
    ;;

  *)
    echo "usage: mode_switch.sh {apply <sound|fast>|current|status}"
    ;;
esac
