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
#   改的是 k90 调音模块提供的 audio_module_config_primary.xml（模块源文件，
#   位于可写的 f2fs 上），改完重新 bind mount 到 /odm 生效。
#   /odm 本身只读，无法直接在其上 sed -i。
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
SRC=/data/adb/modules/k90pm_audio_plus/Link/odm/etc/audio/audio_module_config_primary.xml
DAEMON=$MOD/hyper-audio
STARTER=$MOD/bin/start_daemon.sh
LOG=/data/local/tmp/hyper-audio.log

get_mode() {
  M=$(cat "$MODEFILE" 2>/dev/null | tr -d ' \r\n')
  case "$M" in sound|fast) echo "$M" ;; *) echo sound ;; esac
}

# 守护进程是否在运行：pidof 最可靠（pgrep -f 与 PID 文件在本设备上都不稳）
daemon_running() {
  [ -n "$(pidof hyper-audio 2>/dev/null)" ]
}

start_daemon() {
  daemon_running && return 0
  # 用独立启动器 + setsid：确保守护进程完全脱离本脚本，
  # 否则本脚本退出（或 killall audioserver）时会把同会话的子进程一起带走。
  if [ -x "$STARTER" ]; then
    setsid sh "$STARTER" >/dev/null 2>&1 < /dev/null
  else
    [ -x "$DAEMON" ] || return 1
    cd "$MOD" && setsid ./hyper-audio >> "$LOG" 2>&1 < /dev/null &
  fi
  sleep 1
  P=$(pidof hyper-audio 2>/dev/null | awk '{print $1}')
  [ -n "$P" ] && printf '%s\n' "$P" > "$PIDFILE"
  return 0
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
  [ -f "$SRC" ] || { echo "warn=config_missing"; return 0; }

  if [ "$M" = "sound" ]; then
    sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)FAST PRIMARY">|\1PRIMARY">|' "$SRC"
    sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)FAST RAW">|\1RAW">|' "$SRC"
  else
    sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$SRC"
    sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$SRC"
  fi
  chmod 644 "$SRC" 2>/dev/null

  umount "$DST" 2>/dev/null
  mount --bind "$SRC" "$DST" 2>/dev/null
  restorecon "$DST" 2>/dev/null
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
    printf '%s\n' "$M" > "$MODEFILE" 2>/dev/null
    chmod 644 "$MODEFILE" 2>/dev/null
    apply_flags "$M"
    if [ "$M" = "sound" ]; then stop_daemon; else start_daemon; fi
    killall audioserver 2>/dev/null
    update_desc
    echo "ok=1"
    echo "mode=$M"
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
