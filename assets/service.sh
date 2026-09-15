#!/bin/sh
# ============================================================
# hyperaudio — 开机启动
# ============================================================
# 时机：由 KernelSU/Magisk 启动，晚于所有模块的 post-fs-data.sh，
#       此时 k90 调音模块已把 audio_module_config_primary.xml 挂载到 /odm。
#
# 逻辑：按 mode 文件决定行为
#   sound（音效模式，默认）：应用"摘 FAST"补丁 → 全局走效果链；不启动守护进程
#   fast （低延迟模式）：恢复 FAST 补丁 → 启动 hyper-audio 守护进程（RT 提权）
# ============================================================
MODDIR=${0%/*}

chmod +x "$MODDIR/hyper-audio" 2>/dev/null
chmod +x "$MODDIR/bin/mode_switch.sh" 2>/dev/null
chmod +x "$MODDIR/bin/start_daemon.sh" 2>/dev/null

# 读取模式（默认 sound）
MODE=$(cat "$MODDIR/mode" 2>/dev/null | tr -d ' \r\n')
case "$MODE" in sound|fast) ;; *) MODE=sound ;; esac

# 应用端口标志
if [ -x "$MODDIR/bin/mode_switch.sh" ]; then
  sh "$MODDIR/bin/mode_switch.sh" apply "$MODE" >/dev/null 2>&1
fi

# 低延迟模式下才需要守护进程
if [ "$MODE" = "fast" ]; then
  if [ -x "$MODDIR/bin/start_daemon.sh" ]; then
    setsid sh "$MODDIR/bin/start_daemon.sh" >/dev/null 2>&1 < /dev/null &
  else
    exec "$MODDIR/hyper-audio"
  fi
fi
