#!/system/bin/sh
MODDIR=${0%/*}/..
case "$1:$2" in
    fonts:) [ "$#" = 1 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    status:|router-status:|perapp-add:|perapp-del:|perapp-enable:|wl-add:|wl-del:|diagnose:|diag-status:|tuning:|ll-status:|boot-status:|start-backends:|theme:|debug-summary:|debug-reports:|perapp-enable:0|perapp-enable:1) ;;
    ll-save:*)
        [ "$#" = 5 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        # 参数：enabled hal audio app（白名单由 wl-add/wl-del 单独维护）
        case "$2" in 0|1) ;; *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
        for ARG in "$3" "$4" "$5"; do
            case "$ARG" in ''|*[!0-9]*|0*) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
            { [ "${#ARG}" -le 2 ] && [ "$ARG" -ge 1 ] && [ "$ARG" -le 99 ]; } || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        done ;;
    debug-analyze:*)
        [ "${#2}" -le 100 ] && printf '%s\n' "$2" | grep -Eq '^hyperaudio-(native|sound|compat|unknown)-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz$' || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    schedule-diagnose:*)
        [ "${#2}" -le 200 ] && printf '%s\n' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$' || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;;
esac
case "$1" in ll-save) ;; *) [ "$#" -le 2 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;; esac
OUT=$(/system/bin/sh "$MODDIR/bin/ha.sh" "$@" 2>&1)
RC=$?
B64=$(printf '%s' "$OUT" | base64 | tr -d '\r\n')
printf 'rc=%s|%s\n' "$RC" "$B64"
exit "$RC"
