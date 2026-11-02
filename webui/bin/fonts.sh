#!/system/bin/sh
# UI-only export. Reads the active Android font service and copies at most two
# bounded font assets to this module's webroot. No audio settings are touched.
font_allowed_path() {
    case "$1" in ''|*[!A-Za-z0-9_./-]*|*/../*|*/./*) return 1 ;; esac
    case "$1" in
        /system/fonts/*|/system_ext/fonts/*|/product/fonts/*|/vendor/fonts/*|/odm/fonts/*|/data/fonts/*|/data/system/theme/fonts/*) return 0 ;;
        *) return 1 ;;
    esac
}
font_export() {
    FONT_ROLE=$1; FONT_SOURCE=$2
    case "$FONT_ROLE" in latin|han) ;; *) return 1 ;; esac
    font_allowed_path "$FONT_SOURCE" || return 1
    FONT_REAL=$(readlink -f "$FONT_SOURCE") || return 1
    font_allowed_path "$FONT_REAL" || return 1
    [ -f "$FONT_REAL" ] && [ -r "$FONT_REAL" ] || return 1
    FONT_SIZE=$(stat -c %s "$FONT_REAL") || return 1
    case "$FONT_SIZE" in ''|*[!0-9]*) return 1 ;; esac
    [ "$FONT_SIZE" -ge 12 ] && [ "$FONT_SIZE" -le 33554432 ] || return 1
    FONT_MAGIC=$(od -An -tx1 -N4 "$FONT_REAL" | tr -d ' \r\n')
    case "$FONT_MAGIC" in
        00010000|74727565) FONT_EXT=ttf ;;
        4f54544f) FONT_EXT=otf ;;
        74746366) FONT_EXT=ttc ;;
        *) return 1 ;;
    esac
    FONT_HASH=$(sha256sum "$FONT_REAL") || return 1; FONT_HASH=${FONT_HASH%% *}
    case "$FONT_HASH" in *[!a-f0-9]*|'') return 1 ;; esac
    [ "${#FONT_HASH}" = 64 ] || return 1
    FONT_NAME=$FONT_ROLE-$FONT_HASH.$FONT_EXT
    FONT_DEST=$FONT_CACHE/$FONT_NAME
    [ ! -L "$FONT_DEST" ] || return 1
    if [ ! -f "$FONT_DEST" ]; then
        # The dedicated directory and lock prevent concurrent exports. Atomic
        # rename prevents the WebView reading a partially copied font.
        [ ! -e "$FONT_CACHE/pending" ] && [ ! -L "$FONT_CACHE/pending" ] || return 1
        cp "$FONT_REAL" "$FONT_CACHE/pending" || return 1
        chmod 644 "$FONT_CACHE/pending" || return 1
        FONT_COPY_HASH=$(sha256sum "$FONT_CACHE/pending") || return 1
        [ "${FONT_COPY_HASH%% *}" = "$FONT_HASH" ] || return 1
        mv "$FONT_CACHE/pending" "$FONT_DEST" || return 1
    fi
    # At most one previous file for the same slot can survive an interrupted
    # cleanup. Only our validated hash filenames are removed; no recursive rm.
    for FONT_OLD in "$FONT_CACHE/$FONT_ROLE-"*; do
        [ "$FONT_OLD" != "$FONT_DEST" ] || continue
        FONT_OLD_NAME=${FONT_OLD##*/}
        printf '%s\n' "$FONT_OLD_NAME" | grep -Eq '^(latin|han)-[a-f0-9]{64}\.(ttf|otf|ttc)$' || continue
        [ ! -L "$FONT_OLD" ] && [ -f "$FONT_OLD" ] && rm -f "$FONT_OLD"
    done
    printf 'font_%s=./system-fonts/%s\n' "$FONT_ROLE" "$FONT_NAME"
}
font_status() (
    FONT_CACHE=$MODDIR/webroot/system-fonts
    [ ! -L "$FONT_CACHE" ] || { echo font_source=webview; return 0; }
    mkdir -p "$FONT_CACHE" || { echo font_source=webview; return 0; }
    [ "$(readlink -f "$FONT_CACHE")" = "$MODDIR/webroot/system-fonts" ] || { echo font_source=webview; return 0; }
    # Font reads have their own lock and never block audio mode switching.
    [ ! -L "$FONT_CACHE/export.lock" ] || { echo font_source=webview; return 0; }
    exec 9>"$FONT_CACHE/export.lock" || { echo font_source=webview; return 0; }
    # Kernel releases flock even if a container kills the command, so a stale
    # lock directory cannot leave system-font detection disabled indefinitely.
    flock -n 9 || { echo font_source=webview; return 0; }
    trap 'rm -f "$FONT_CACHE/pending"' EXIT
    trap 'exit 130' INT TERM HUP
    FONT_DUMP=$(timeout 4 cmd font dump sans-serif 2>/dev/null) || { echo font_source=webview; return 0; }
    [ "${#FONT_DUMP}" -le 262144 ] || { echo font_source=webview; return 0; }
    FONT_SELECTION=$(printf '%s\n' "$FONT_DUMP" | awk -f "$MODDIR/bin/system_fonts.awk")
    FONT_RESULT=$(printf '%s\n' "$FONT_SELECTION" | while IFS='|' read -r FONT_SLOT FONT_PATH FONT_INDEX; do
        [ "$FONT_INDEX" = 0 ] && font_export "$FONT_SLOT" "$FONT_PATH"
    done)
    if [ -n "$FONT_RESULT" ]; then
        echo font_source=android_font_service
        printf '%s\n' "$FONT_RESULT"
    else
        echo font_source=webview
    fi
)
