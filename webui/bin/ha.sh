#!/system/bin/sh
MODDIR=$(CDPATH= cd -- "${0%/*}/.." && pwd -P) || exit 1
export MODDIR
# Re-enter a predictable BusyBox shell for both root managers and terminal/WebUI.
if [ "$HA_BUSYBOX" != 1 ]; then
    for BB in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$BB" ]; then
            export HA_BUSYBOX=1 ASH_STANDALONE=1
            exec "$BB" sh "$0" "$@"
        fi
    done
    echo error=manager_busybox_missing
    exit 1
fi
[ "$(id -u)" = 0 ] || { echo error=root_required; exit 1; }
# 模块不再做 bind mount / resetprop / 重启 audioserver，因此不需要进入 init 的挂载命名空间。
. "$MODDIR/bin/runtime.sh"
. "$MODDIR/bin/diagnostics.sh"
. "$MODDIR/bin/sampling.sh"
. "$MODDIR/bin/lowlat.sh"
. "$MODDIR/bin/boot.sh"
. "$MODDIR/bin/debug.sh"
. "$MODDIR/bin/theme.sh"
. "$MODDIR/bin/fonts.sh"
# Android offers /proc/sys/kernel/random/boot_id. HA_BOOT_ID lets host tests pin it.
BOOT_ID=${HA_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}
[ -n "$BOOT_ID" ] || exit 1
mkdir -p "$STATE" 2>/dev/null

# 只读与后台动作：不持锁、不改状态。
case "$1" in
    theme) theme_status; exit $? ;;
    fonts) [ "$#" = 1 ] || exit 1; font_status; exit $? ;;
    debug-summary) debug_summary; exit $? ;;
    debug-reports) debug_reports; exit $? ;;
    debug-analyze) debug_analyze "$2"; exit $? ;;
    rt-daemon) ll_daemon; exit $? ;;
    ll-status) ll_status; exit $? ;;
    boot-status) boot_status; exit $? ;;
    diag-daemon) diagnostic_daemon; exit $? ;;
    diagnose-target)
        valid_target "$2" || exit 1
        case "$3" in native|compat|sound) ;; *) exit 1 ;; esac
        DIAG_TARGET=$2
        DIAG_EXPECTED_MODE=$3
        run_diagnostics; exit $? ;;

    diagnose) run_diagnostics; exit $? ;;
    diag-status) diag_status; exit $? ;;
    tuning) detect_tuning; exit $? ;;
  router-status|perapp-add|perapp-del|wl-add|wl-del)
    /system/bin/sh "$MODDIR/bin/router.sh" "$@"; exit $? ;;
esac

case "$1" in
    status) status ;;
    ll-save) shift; ll_save "$@" ;;
    start-backends)
        ll_ensure_daemon || exit 1
        if ! daemon_alive; then
            HA_BUSYBOX=0 setsid /system/bin/sh "$MODDIR/bin/ha.sh" diag-daemon </dev/null > "$STATE/diag-daemon.log" 2>&1 &
            sleep 1
        fi
        daemon_alive || { echo error=diagnostic_backend_not_running; exit 1; }
        echo ok=1 ;;
    boot) boot_run ;;
    stop)
        # 卸载/禁用前调用：先把已提升的线程逐一还原，再结束调度 daemon。
        ll_pause || exit 1
        _p=$(cat "$LLROOT/daemon.pid" 2>/dev/null)
        case "$_p" in ''|*[!0-9]*) ;; *) kill "$_p" 2>/dev/null; rm -f "$LLROOT/daemon.pid" ;; esac
        echo ok=1 ;;
    schedule-diagnose) queue_diagnostics "$2" ;;
    *) echo 'usage: ha.sh {status|router-status|perapp-add|perapp-del|wl-add|wl-del|ll-save HAL AUDIO APP|ll-status|boot|boot-status|stop|diagnose|schedule-diagnose PACKAGE|diag-status|tuning|start-backends|debug-summary|debug-reports|debug-analyze NAME}'; exit 1 ;;
esac
