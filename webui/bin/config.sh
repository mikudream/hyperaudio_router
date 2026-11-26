#!/system/bin/sh
# Use an fd lock when available so interruption releases it automatically.
# Android builds without flock use a boot-scoped mkdir lock. Never remove a
# contender's lock: a hard kill can require reboot, but cannot admit two writers.
config_lock() {
    local n=0 boot
    mkdir -p "$STATE" || return 1
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$STATE/config.flock" || return 1
        while ! flock -xn 9; do
            n=$((n+1)); [ "$n" -le 20 ] || { exec 9>&-; return 1; }
            sleep 1
        done
        CONFIG_LOCK_MODE=fd
        return 0
    fi
    boot=${BOOT_ID:-${HA_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}}
    case "$boot" in ''|*[!A-Za-z0-9-]*) boot=unknown ;; esac
    CONFIG_LOCK_DIR=$STATE/config.lock.$boot
    while ! mkdir "$CONFIG_LOCK_DIR" 2>/dev/null; do
        n=$((n+1)); [ "$n" -le 20 ] || return 1
        sleep 1
    done
    CONFIG_LOCK_MODE=dir
    # Older boot locks can no longer have live owners.
    for boot in "$STATE"/config.lock.*; do
        [ "$boot" = "$CONFIG_LOCK_DIR" ] || rmdir "$boot" 2>/dev/null || :
    done
}
config_unlock() {
    case "${CONFIG_LOCK_MODE:-}" in
      fd) exec 9>&- ;;
      dir) rmdir "$CONFIG_LOCK_DIR" 2>/dev/null ;;
    esac
    CONFIG_LOCK_MODE=
}

# Restore interrupted two-list migrations before taking a new snapshot.
config_recover() {
    local txn=$STATE/config-txn f p old g
    [ -d "$txn" ] || return 0
    if [ -f "$txn/pending" ]; then
        while IFS= read -r f; do
            case "$f" in perapp.conf|lowlat.conf) ;; *) return 1 ;; esac
            if [ -f "$txn/$f.old" ]; then
                cp -p "$txn/$f.old" "$txn/$f.restore" &&
                    mv -f "$txn/$f.restore" "$MODDIR/$f" || return 1
            elif [ -f "$txn/$f.absent" ]; then
                rm -f "$MODDIR/$f" || return 1
            fi
        done < "$txn/undo-files"
        while IFS= read -r p; do
            case "$p" in perapp.app|mmap_gate) ;; *) return 1 ;; esac
            old=$(cat "$txn/$p.active") || return 1
            g=$(cat "$txn/$p.gen") || return 1
            if [ "$(getprop "ha.$p.active" 2>/dev/null)" != "$old" ]; then
                setprop "ha.$p.active" "$old" >/dev/null 2>&1 || return 1
                [ "$(getprop "ha.$p.active" 2>/dev/null)" = "$old" ] || return 1
            fi
            if [ "$(getprop "ha.$p.gen" 2>/dev/null)" != "$g" ]; then
                setprop "ha.$p.gen" "$g" >/dev/null 2>&1 || return 1
                [ "$(getprop "ha.$p.gen" 2>/dev/null)" = "$g" ] || return 1
            fi
        done < "$txn/undo-props"
        rm -f "$txn/pending" || return 1
    fi
    rm -rf "$txn"
}

config_lowlat_write() {
    printf 'hal_priority=%s\naudio_priority=%s\napp_priority=%s\nwhitelist=%s\nrevision=%s-%s\n' \
        "$1" "$2" "$3" "$4" "$(date +%s)" "$$"
}

config_pkg_ok() {
    case "$1" in ''|*[!A-Za-z0-9_.]*) return 1 ;; esac
    case "$1" in *.*) ;; *) return 1 ;; esac
    case "$1" in [0-9]*|.*|*.|*..*) return 1 ;; esac
    [ "${#1}" -le 120 ]
}
