#!/system/bin/sh
# ============================================================
# hyperaudio 开机初始化
# ============================================================
# 放在 /data/adb/service.d/，由 KernelSU/Magisk 在开机后期执行。
# 执行时机晚于各模块的 post-fs-data.sh，因此 k90 调音模块此时已把
# /odm/etc/audio/audio_module_config_primary.xml 挂载好，本脚本可在此基础上
# 按所选模式打补丁。
#
# 注意：本模块不对系统音频库做任何遮蔽（挖空 *impl.so 只会让策略层失效，
#       对"阻止应用拿到 ULL"没有任何帮助，已由实测确认）。
# ============================================================

MOD=/data/adb/modules/hyperaudio
MSW=$MOD/bin/mode_switch.sh
LOG=/data/local/tmp/hyperaudio-init.log

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

[ -d "$MOD" ] || { log "模块目录不存在，退出"; exit 0; }
: > "$LOG"
log "初始化开始"

# 1. 按当前模式应用音频端口标志（默认 sound）
if [ -f "$MSW" ]; then
  M=$(cat "$MOD/mode" 2>/dev/null | tr -d ' \r\n')
  case "$M" in sound|fast) ;; *) M=sound ;; esac
  log "模式 = $M"
  sh "$MSW" apply "$M" >> "$LOG" 2>&1
  log "模式已应用"
else
  log "warn: 找不到 $MSW"
fi

# 2. 低延迟模式下启动 hyper-audio 守护进程（音效模式下 mode_switch 会停掉它）
if [ "$(cat "$MOD/mode" 2>/dev/null | tr -d ' \r\n')" = "fast" ]; then
  if [ -x "$MOD/hyper-audio" ] && ! pgrep -f "$MOD/hyper-audio" >/dev/null 2>&1; then
    cd "$MOD" && setsid ./hyper-audio >> /data/local/tmp/hyper-audio.log 2>&1 < /dev/null &
    log "hyper-audio 已启动"
  fi
fi

log "初始化完成"
