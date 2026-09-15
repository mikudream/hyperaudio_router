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

case "$1" in
  apply)
    M="$2"
    case "$M" in sound|fast) ;; *) echo "error=bad_mode"; exit 1 ;; esac
    printf '%s\n' "$M" > "$MODEFILE" 2>/dev/null
    chmod 644 "$MODEFILE" 2>/dev/null
    apply_flags "$M"
    if [ "$M" = "sound" ]; then stop_daemon; else start_daemon; fi
    killall audioserver 2>/dev/null
    echo "ok=1"
    echo "mode=$M"
    ;;

  current)
    get_mode
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
