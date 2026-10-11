#!/system/bin/sh
# ============================================================
# hyperaudio — 开机启动
# ============================================================
# 时机：由 KernelSU/Magisk 启动，晚于所有模块的 post-fs-data.sh，
#       此时调音模块已把 audio_module_config_primary.xml 挂载到 /odm。
#
# 逻辑：交给 bin/runtime.sh boot 处理，它包含：
#   · 按 mode 文件应用（sound 摘 FAST / fast 还原）
#   · **开机护栏**：若上次启动或切换未收尾（存在 state/pending），
#     或上次开机应用失败（state/boot.failure），本次强制回到原始配置
#     并记录原因，**绝不反复重试一个已知失败的配置**。
#   · 同一次启动只执行一次（用 boot_id 去重）。
#
# 说明：端口补丁、简介刷新、守护进程启停全部由 runtime.sh 完成，
#       避免同一逻辑两处维护。
# ============================================================
MODDIR=${0%/*}

chmod +x "$MODDIR/hyper-audio" 2>/dev/null
chmod +x "$MODDIR/action.sh" 2>/dev/null
chmod +x "$MODDIR/bin/runtime.sh" 2>/dev/null
chmod +x "$MODDIR/bin/start_daemon.sh" 2>/dev/null

# 端口补丁用 awk 完成，需要可执行（busybox awk 也能跑，但有的 shell 会查执行位）
chmod 0644 "$MODDIR/bin/patch_ports.awk" 2>/dev/null

# 注意用 -f 而不是 -x：安装后脚本可能没有执行位。
# 中间状态兜底：只有 runtime.sh 不存在时才回退到旧的 mode_switch.sh。
RSW=$MODDIR/bin/runtime.sh
[ -f "$RSW" ] || RSW=$MODDIR/bin/mode_switch.sh

if [ -f "$RSW" ]; then
  LOG=/data/local/tmp/hyperaudio-init.log
  {
    echo "[service.sh] boot $(date 2>/dev/null)"
    if [ -f "$MODDIR/bin/runtime.sh" ]; then
      sh "$MODDIR/bin/runtime.sh" boot 2>&1
    else
      # 旧脚本没有 boot 子命令，按 mode 文件应用即可
      MODE=""
      [ -f "$MODDIR/mode" ] && IFS= read -r MODE < "$MODDIR/mode" 2>/dev/null
      MODE=${MODE%$'\r'}
      case "$MODE" in sound|fast) ;; *) MODE=sound ;; esac
      sh "$RSW" apply "$MODE" 2>&1
    fi
  } >> "$LOG" 2>/dev/null
fi
