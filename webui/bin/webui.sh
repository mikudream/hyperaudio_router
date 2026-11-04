#!/system/bin/sh
MODDIR=${0%/*}/..
case "$1:$2" in
    fonts:) [ "$#" = 1 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;;
    status:|router-status:|tuning:|ll-status:|boot-status:|start-backends:|theme:) ;;
    # 带包名的动作必须用 perapp-add:* 这种通配，否则 "perapp-add:com.xxx" 永远匹配不上
    perapp-add:*|perapp-del:*|wl-add:*|wl-del:*) ;;
    ll-save:*)
        [ "$#" = 4 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        # 参数：hal audio app（名单由 wl-add/wl-del 维护；没有总开关）
        for ARG in "$2" "$3" "$4"; do
            case "$ARG" in ''|*[!0-9]*|0*) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;; esac
            { [ "${#ARG}" -le 2 ] && [ "$ARG" -ge 1 ] && [ "$ARG" -le 99 ]; } || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; }
        done ;;
    *) echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1 ;;
esac
case "$1" in ll-save) ;; *) [ "$#" -le 2 ] || { echo 'rc=1|YmFkX2NvbW1hbmQ='; exit 1; } ;; esac
OUT=$(/system/bin/sh "$MODDIR/bin/ha.sh" "$@" 2>&1)
RC=$?
B64=$(printf '%s' "$OUT" | base64 | tr -d '\r\n')
printf 'rc=%s|%s\n' "$RC" "$B64"
exit "$RC"
