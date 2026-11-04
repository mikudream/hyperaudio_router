#!/system/bin/sh
# 设置页“已启用的调音模块”检测：扫描其它模块里的调音载荷文件。
detect_tuning() {
    TN=0
    for TD in /data/adb/modules/*; do
        [ -f "$TD/module.prop" ] || continue
        [ ! -f "$TD/disable" ] && [ ! -f "$TD/remove" ] || continue
        case "${TD##*/}" in hyperaudio|hyperaudio) continue ;; esac
        HIT=""
        for TB in "$TD/Link/odm/etc" "$TD/Link/vendor/etc" "$TD/odm/etc" "$TD/vendor/etc" "$TD/system/vendor/etc" "$TD/system/etc"; do
            [ -d "$TB" ] || continue
            HIT=$(find "$TB" -maxdepth 6 -type f \( -name 'dax-*.xml' -o -name 'dax_default*' -o -name 'mixer_paths*.xml' -o -name 'audio_effects*.xml' -o -name 'audio_effects*.json' -o -name '*.acdb' \) -print -quit 2>/dev/null)
            [ -z "$HIT" ] || break
        done
        [ -n "$HIT" ] || continue
        TN=$((TN + 1))
        TNAME=$(sed -n 's/^name=//p' "$TD/module.prop" | head -n 1)
        TVER=$(sed -n 's/^version=//p' "$TD/module.prop" | head -n 1)
        printf 'source=%s | %s | %s\n' "${TD##*/}" "$TNAME" "$TVER"
    done
    echo "count=$TN"
    echo "evidence=发现已启用模块中的调音载荷；未验证这些载荷是否作用于当前游戏。"
}
