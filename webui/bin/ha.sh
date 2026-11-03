#!/system/bin/sh
MODDIR=$(CDPATH= cd -- "${0%/*}/.." && pwd -P) || exit 1
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
# Bind mounts must be visible in audioserver's init namespace, not only WebUI's su shell.
SELF_NS=$(readlink /proc/self/ns/mnt)
INIT_NS=$(readlink /proc/1/ns/mnt)
[ -n "$SELF_NS" ] && [ -n "$INIT_NS" ] || { echo error=cannot_read_mount_namespace; exit 1; }
if [ "$SELF_NS" != "$INIT_NS" ]; then
    [ "$HA_NS_TRIED" = 1 ] && { echo error=cannot_enter_init_mount_namespace; exit 1; }
    export HA_NS_TRIED=1
    for BB in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
        [ -x "$BB" ] && exec "$BB" nsenter -t 1 -m -- "$BB" sh "$0" "$@"
    done
    echo error=nsenter_unavailable
    exit 1
fi
. "$MODDIR/bin/runtime.sh"
. "$MODDIR/bin/diagnostics.sh"
. "$MODDIR/bin/sampling.sh"
. "$MODDIR/bin/lowlat.sh"
. "$MODDIR/bin/debug.sh"
. "$MODDIR/bin/theme.sh"
. "$MODDIR/bin/fonts.sh"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id) || exit 1
[ -n "$BOOT_ID" ] || exit 1
# A diagnostic worker never changes properties, mounts or audio services and does
# not hold the mode-switch lock while collecting. Native recovery stays available.
case "$1" in
    theme) theme_status; exit $? ;;
    fonts) [ "$#" = 1 ] || exit 1; font_status; exit $? ;;
    debug-summary) debug_summary; exit $? ;;
    debug-reports) debug_reports; exit $? ;;
    debug-analyze) debug_analyze "$2"; exit $? ;;
    rt-daemon) ll_daemon; exit $? ;;
    ll-status) ll_status; exit $? ;;
    boot-status) boot_status; exit $? ;;
    sound-status) sound_status; exit $? ;;
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
esac
lock_state || { echo error=operation_in_progress; exit 1; }
trap 'unlock_state' EXIT
trap 'exit 130' INT TERM HUP
prepare_boot || { err cannot_capture_boot_state; exit 1; }
case "$1" in
    apply)
        ll_pause || exit 1
        apply_mode "$2"; RC=$?
        ll_resume
        [ "$RC" != 0 ] || ll_ensure_daemon || RC=1
        exit "$RC" ;;
    recover)
        recover_native ;;
    boot-save) shift; boot_save "$@" ;;
    sound-save) shift; sound_save "$@" ;;
    sound-reset) sound_reset ;;
    ll-save) shift; ll_save "$@" ;;
    start-backends)
        ll_ensure_daemon || exit 1
        if ! daemon_alive; then
            HA_BUSYBOX=0 setsid /system/bin/sh "$MODDIR/bin/ha.sh" diag-daemon </dev/null > "$STATE/diag-daemon.log" 2>&1 &
            sleep 1
        fi
        daemon_alive || { echo error=diagnostic_backend_not_running; exit 1; }
        echo ok=1 ;;
    cycle)
        case "$(read_mode)" in native) NEXT=sound ;; *) NEXT=native ;; esac
        ll_pause || exit 1
        apply_mode "$NEXT"; RC=$?
        ll_resume
        exit "$RC"
        ;;
    boot)
        boot_run
        ;;
    status) status ;;
    schedule-diagnose) queue_diagnostics "$2" ;;
    *) echo 'usage: ha.sh {apply native|compat|sound|cycle|status|boot-status|boot-save native|sound|sound-status|sound-save CUSTOM MMAP FAST_LOW FAST_RAW RAW|sound-reset|diagnose|schedule-diagnose PACKAGE|diag-status|tuning|ll-status|ll-save ENABLE HAL AUDIO APP|recover|start-backends}'; exit 1 ;;
esac
