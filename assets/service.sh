#!/system/bin/sh
# ============================================================
# hyperaudio — 开机启动
# ============================================================
# 时机：由 KernelSU/Magisk 启动，晚于所有模块的 post-fs-data.sh，
#       此时调音模块已把 audio_module_config_primary.xml 挂载到 /odm。
#
# 逻辑：按 mode 文件决定行为
#   sound（音效模式，默认）：应用"摘 FAST"补丁 → 全局走效果链；不启动守护进程
#   fast （低延迟模式）：恢复 FAST 补丁 → 启动 hyper-audio 守护进程（RT 提权）
#
# 说明：本脚本只负责"按当前模式应用一次"；端口补丁、简介刷新、守护进程启停
#       全部由 bin/mode_switch.sh apply 完成，避免同一逻辑两处维护。
# ============================================================
MODDIR=${0%/*}

chmod +x "$MODDIR/hyper-audio" 2>/dev/null
chmod +x "$MODDIR/action.sh" 2>/dev/null
chmod +x "$MODDIR/bin/mode_switch.sh" 2>/dev/null
chmod +x "$MODDIR/bin/start_daemon.sh" 2>/dev/null

# 读取模式（默认 sound）。用内建 read，避免 cat|tr 两个进程。
MODE=""
[ -f "$MODDIR/mode" ] && IFS= read -r MODE < "$MODDIR/mode" 2>/dev/null
MODE=${MODE%$'\r'}
case "$MODE" in sound|fast) ;; *) MODE=sound ;; esac

# 应用端口标志（内部会一并刷新 module.prop 的「当前模式」前缀、
# 并按模式启停守护进程）。注意用 -f 而不是 -x：安装后脚本可能没有执行位。
if [ -f "$MODDIR/bin/mode_switch.sh" ]; then
  LOG=/data/local/tmp/hyperaudio-init.log
  {
    echo "[service.sh] mode=$MODE $(date 2>/dev/null)"
    sh "$MODDIR/bin/mode_switch.sh" apply "$MODE" 2>&1
  } >> "$LOG" 2>/dev/null
fi
