#!/system/bin/sh
MODDIR=${0%/*}
echo "HyperOS 音频模式切换器"
# Keep the backend's structured output for WebUI/CLI; present only a short,
# confirmed result in the manager's action console.
OUTPUT=$(/system/bin/sh "$MODDIR/bin/ha.sh" cycle 2>&1)
RC=$?
CONFIRMED=0
MODE=
ERROR=
while IFS= read -r LINE || [ -n "$LINE" ]; do
    case "$LINE" in
        ok=1) CONFIRMED=1 ;;
        mode=*) MODE=${LINE#mode=} ;;
        error=*) ERROR=${LINE#error=} ;;
    esac
done <<EOF
$OUTPUT
EOF

if [ "$RC" = 0 ] && [ "$CONFIRMED" = 1 ] && [ -z "$ERROR" ]; then
    case "$MODE" in
        native) echo "已切换至原生模式。" ;;
        sound) echo "已切换至音效模式。" ;;
        *) MODE= ;;
    esac
    if [ -n "$MODE" ]; then
        echo "无需重启手机，请强行停止并重新打开游戏。"
        exit 0
    fi
fi

# The last error describes the final rollback result, which takes precedence
# over the earlier cause. Never print successful-switch advice after failure.
case "$ERROR" in
    operation_in_progress|scheduler_busy_try_again)
        echo "切换未执行：另一个操作正在进行，请稍后重试。" ;;
    apply_failed_restored_native)
        echo "切换失败，已恢复原生模式。"
        echo "请在 WebUI 的 Debug 中采集日志排查。" ;;
    *_reboot_required)
        echo "切换失败，音频恢复需要重启手机。"
        echo "请重启后在 WebUI 中检查当前模式。" ;;
    root_required)
        echo "切换失败：未取得 Root 权限。" ;;
    manager_busybox_missing|resetprop_missing)
        echo "切换失败：管理器的必要工具不可用。"
        echo "请检查 Root 与管理器安装。" ;;
    cannot_read_mount_namespace|cannot_enter_init_mount_namespace|nsenter_unavailable)
        echo "切换失败：无法访问系统音频运行环境。" ;;
    old_hyperaudio_still_installed)
        echo "切换未执行：检测到冲突的旧版 HyperAudio 模块。"
        echo "请按安装说明移除旧版，再重试。" ;;
    *)
        echo "切换未完成，请在 WebUI 中检查当前模式。"
        echo "可在 Debug 中采集日志排查。" ;;
esac
[ "$RC" != 0 ] || RC=1
exit "$RC"
