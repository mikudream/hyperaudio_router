#!/system/bin/sh
# Startup preference is independent of the currently applied mode.
# Parse configuration as data; never source or evaluate it.
boot_read_config() {
    BOOT_MODE=native
    [ -f "$MODDIR/boot.conf" ] || return 0
    local value
    value=$(awk 'NR == 1 && ($0 == "mode=native" || $0 == "mode=sound") {v=substr($0,6)} END {if (NR != 1 || v == "") exit 1; print v}' "$MODDIR/boot.conf") || return 1
    BOOT_MODE=$value
}
boot_guard_reason() {
    local reason
    reason=$(cat "$STATE/boot.failure" 2>/dev/null)
    case "$reason" in
        interrupted_startup_or_transition|invalid_boot_config|invalid_lowlat_config|startup_apply_failed|startup_scheduler_failed) echo "$reason" ;;
        '') if [ -f "$STATE/boot.failure" ]; then echo previous_failure; else echo none; fi ;;
        *) echo previous_failure ;;
    esac
}
boot_status() {
    if boot_read_config; then echo boot_config=valid; else echo boot_config=invalid; fi
    echo "boot_mode=$BOOT_MODE"
    echo "boot_guard=$(boot_guard_reason)"
    if [ "$(cat "$STATE/boot.completed" 2>/dev/null)" = "$BOOT_ID" ]; then echo boot_done=yes; else echo boot_done=no; fi
    local result
    result=$(cat "$STATE/boot.result" 2>/dev/null)
    case "$result" in native|sound|guarded_native|failed) echo "boot_result=$result" ;; *) echo boot_result=unknown ;; esac
}
boot_save() {
    [ "$#" = 1 ] || return 1
    case "$1" in native|sound) ;; *) echo error=bad_boot_mode; return 1 ;; esac
    printf 'mode=%s\n' "$1" > "$MODDIR/boot.conf.new" && mv -f "$MODDIR/boot.conf.new" "$MODDIR/boot.conf" || return 1
    # Explicit saving permits a fresh attempt next boot, without changing today.
    rm -f "$STATE/boot.failure" || return 1
    log "saved startup preference $1; current route and scheduler unchanged"
    echo boot_saved=1
    echo "boot_mode=$1"
}
boot_mark_failure() {
    printf '%s\n' "$1" > "$STATE/boot.failure.new" && mv -f "$STATE/boot.failure.new" "$STATE/boot.failure" || return 1
    log "startup guarded: $1; automatic retries disabled until preference is saved"
}
boot_finish() {
    printf '%s\n' "$1" > "$STATE/boot.result" || return 1
    printf '%s\n' "$BOOT_ID" > "$STATE/boot.completed" || return 1
    rm -f "$STATE/boot.pending"
}
boot_run() {
    if [ "$(cat "$STATE/boot.completed" 2>/dev/null)" = "$BOOT_ID" ]; then
        echo boot_skipped=already_handled
        return 0
    fi
    boot_read_config || boot_mark_failure invalid_boot_config || return 1
    local target=$BOOT_MODE guarded=0
    ll_init || return 1
    ll_read_config || boot_mark_failure invalid_lowlat_config || return 1
    if [ "$(boot_guard_reason)" != none ]; then target=native; guarded=1; fi
    printf '%s\n' "$target" > "$STATE/boot.pending" || return 1
    if ! ll_pause; then
        boot_mark_failure startup_scheduler_failed
        boot_finish failed
            update_description native
        return 1
    fi
    if ! apply_mode "$target"; then
        # apply_mode attempts exact native rollback. Keep scheduling paused even
        # if rollback cannot finish; never loop over a failing audio route.
        boot_mark_failure startup_apply_failed
        boot_finish failed
            update_description native
        return 1
    fi
    if [ "$guarded" = 1 ]; then
        boot_finish guarded_native || return 1
            update_description native
        echo 'boot_fallback=native (saved low-latency configuration retained; scheduling paused)'
    else
          # Preserve enabled and priorities byte for byte. The existing
        # daemon schedules only in native mode; sound suspends it naturally.
        ll_resume
        boot_finish "$target" || return 1
    fi
    boot_status
}
recover_native() {
    ll_pause || return 1
    apply_mode native || return 1
    ll_read_config || return 1
    ll_save 0 "$LL_HAL" "$LL_AUDIO" "$LL_APP" || return 1
    boot_save native
}
