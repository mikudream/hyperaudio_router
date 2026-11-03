#!/system/bin/sh
MODDIR=${0%/*}/..
case "$1:$2" in
    fonts:) [ "$#" = 1 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    status:|router-status:|perapp-add:|perapp-del:|perapp-enable:|wl-add:|wl-del:|diagnose:|diag-status:|tuning:|ll-status:|boot-status:|sound-status:|sound-reset:|recover:|start-backends:|theme:|debug-summary:|debug-reports:|apply:native|apply:sound|boot-save:native|boot-save:sound) ;;
    sound-save:*)
        { [ "$#" = 5 ] || [ "$#" = 6 ]; } || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        for ARG in "$2" "$3" "$4" "$5"; do
            case "$ARG" in 0|1) ;; *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
        done
        if [ "$#" = 6 ]; then
            case "$6" in 0|1) ;; *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
        fi ;;
    debug-analyze:*)
        [ "${#2}" -le 100 ] && printf '%s\n' "$2" | grep -Eq '^hyperaudio-(native|sound|compat|unknown)-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz$' || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    ll-save:*)
        [ "$#" = 5 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        # 白名单已移除：参数为 enabled 与三个优先级，共 4 个数值
        for ARG in "$2" "$3" "$4" "$5"; do
            case "$ARG" in ''|*[!0-9]*) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
        done ;;
    schedule-diagnose:*)
        [ "${#2}" -le 200 ] && printf '%s\n' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$' || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;;
esac
case "$1" in ll-save|sound-save) ;; *) [ "$#" -le 2 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;; esac
OUT=$(/system/bin/sh "$MODDIR/bin/ha.sh" "$@" 2>&1)
RC=$?
B64=$(printf '%s' "$OUT" | base64 | tr -d '\r\n')
printf 'rc=%s|%s\n' "$RC" "$B64"
exit "$RC"
