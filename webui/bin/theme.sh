#!/system/bin/sh
# Read actual applied UI mode, not the user's AUTO/CUSTOM preference.
theme_status() {
    UI_DUMP=$(dumpsys -t 3 uimode 2>/dev/null)
    UI_HEX=$(printf '%s\n' "$UI_DUMP" | sed -n 's/.*mSetUiMode=0x\([0-9A-Fa-f]*\).*/\1/p' | head -n 1)
    case "$UI_HEX" in ''|*[!0-9A-Fa-f]*) ;; *)
        if [ "${#UI_HEX}" -le 8 ]; then
            case $((0x$UI_HEX & 48)) in
                32) echo theme=dark; echo source=system; return 0 ;;
                16) echo theme=light; echo source=system; return 0 ;;
            esac
        fi ;;
    esac
    # UI mode dump layouts can vary by vendor. This is a secondary hint only.
    UI_NIGHT=$(printf '%s\n' "$UI_DUMP" | sed -n 's/.*mComputedNightMode=\(true\|false\).*/\1/p' | head -n 1)
    case "$UI_NIGHT" in
        true) echo theme=dark; echo source=system_computed ;;
        false) echo theme=light; echo source=system_computed ;;
        *) echo theme=unknown; echo source=webview ;;
    esac
}
