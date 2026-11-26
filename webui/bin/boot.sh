#!/system/bin/sh
# Late service phase: setprop is not safe during blocking post-fs-data.
boot_status() {
    echo "boot_mode=native"
    echo "boot_guard=none"
    echo "boot_result=ok"
    echo "boot_done=yes"
}

boot_run() {
    mkdir -p "$STATE" || return 1
    printf 'native\n' > "$STATE/applied" || return 1
    local publication
    if publication=$(sh "$MODDIR/bin/router.sh" publish-only 2>&1); then
        echo config_publish=ok
    else
        echo config_publish=failed
        log "property publication failed: $publication"
    fi
    ll_ensure_daemon || return 1
    log "boot: applied=native whitelist=$(count_wl)"
    echo ok=1
    boot_status
    ll_status 2>/dev/null | sed -n '/^ll_state=/p'
    return 0
}
