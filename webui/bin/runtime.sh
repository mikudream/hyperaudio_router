#!/system/bin/sh
# Loaded by ha.sh after entering init's mount namespace.
# All mutations are scoped to this module's state, two volatile properties,
# and at most ONE owned bind mount above the existing target.
STATE=$MODDIR/state
PROPS="aaudio.mmap_policy aaudio.mmap_exclusive_policy"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$STATE/events.log"; }
err() { printf 'error=%s\n' "$*"; log "ERROR $*"; return 1; }
read_mode() {
    M=$(cat "$MODDIR/mode" 2>/dev/null)
    case "$M" in native|compat|sound) printf '%s\n' "$M" ;; *) echo native ;; esac
}
name_mode() {
    case "$1" in native) echo 原生模式 ;; compat) echo 兼容模式 ;; sound) echo 音效模式 ;; *) echo 未知 ;; esac
}
write_mode() {
    printf '%s\n' "$1" > "$MODDIR/mode.new" && mv -f "$MODDIR/mode.new" "$MODDIR/mode"
}
find_resetprop() {
    RP=$(command -v resetprop 2>/dev/null)
    [ -n "$RP" ] && return 0
    for R in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop /sbin/resetprop; do
        [ -x "$R" ] && { RP=$R; return 0; }
    done
    RP=""
    for R in /data/adb/magisk/magisk /sbin/magisk; do
        [ -x "$R" ] && { RP=$R; RP_APPLET=1; return 0; }
    done
    return 1
}
rp() { if [ "$RP_APPLET" = 1 ]; then "$RP" resetprop "$@"; else "$RP" "$@"; fi; }
lock_state() {
    umask 077
    mkdir -p "$STATE" || return 1
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        LP=$(cat "$STATE/lock/pid" 2>/dev/null)
        LB=$(cat "$STATE/lock/boot" 2>/dev/null)
        if [ "$LB" = "$BOOT_ID" ]; then
            case "$LP" in ''|*[!0-9]*) return 1 ;; esac
            kill -0 "$LP" 2>/dev/null && return 1
        fi
        rm -f "$STATE/lock/pid" "$STATE/lock/boot"
        rmdir "$STATE/lock" 2>/dev/null || return 1
        mkdir "$STATE/lock" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" > "$STATE/lock/pid"
    printf '%s\n' "$BOOT_ID" > "$STATE/lock/boot"
    return 0
}
unlock_state() {
    rm -f "$STATE/lock/pid" "$STATE/lock/boot"
    rmdir "$STATE/lock" 2>/dev/null
}
prepare_boot() {
    if [ "$(cat "$STATE/boot" 2>/dev/null)" != "$BOOT_ID" ]; then
        # A bind mount cannot survive reboot. Never reuse an OTA-era XML snapshot.
        # An interrupted prior transaction must never be retried automatically.
        if [ -f "$STATE/transaction" ] || [ -f "$STATE/boot.pending" ]; then
            write_mode native || return 1
            boot_mark_failure interrupted_startup_or_transition || return 1
        fi
        rm -f "$STATE"/p.* "$STATE/base.xml" "$STATE/target" "$STATE/owned" "$STATE/active.xml" "$STATE/applied" "$STATE/transaction"
        rm -f "$STATE/boot.pending" "$STATE/boot.completed" "$STATE/boot.result" "$STATE/sound.applied"
        for P in $PROPS; do
            getprop "$P" > "$STATE/p.$P.value" || return 1
            if getprop | grep -F "[$P]:" >/dev/null; then echo 1; else echo 0; fi > "$STATE/p.$P.present"
        done
        echo native > "$STATE/applied"
        printf '%s\n' "$BOOT_ID" > "$STATE/boot"
        log "new boot; original volatile properties captured"
    fi
}
detect_target() {
    TARGET=""
    # Use the live effective configuration, never another module's writable source.
    for T in /odm/etc/audio/audio_module_config_primary.xml /vendor/etc/audio/audio_module_config_primary.xml; do
        if [ -f "$T" ]; then
            [ ! -L "$T" ] || { err symlink_configuration_not_supported; return 1; }
            TARGET=$T; return 0
        fi
    done
    err target_configuration_not_found
}
owned_mount() {
    [ -f "$STATE/owned" ] || return 1
    TARGET=$(cat "$STATE/target" 2>/dev/null)
    case "$TARGET" in /odm/etc/audio/audio_module_config_primary.xml|/vendor/etc/audio/audio_module_config_primary.xml) ;; *) return 1 ;; esac
    [ -f "$TARGET" ] && [ -f "$STATE/active.xml" ] || return 1
    A=$(stat -c '%d:%i' "$TARGET" 2>/dev/null)
    B=$(stat -c '%d:%i' "$STATE/active.xml" 2>/dev/null)
    [ -n "$A" ] && [ "$A" = "$B" ] || return 1
    awk -v p="$TARGET" '$5==p { found=1 } END { exit !found }' /proc/self/mountinfo
}
remove_owned_mount() {
    [ -f "$STATE/owned" ] || return 0
    owned_mount || { err overlay_changed_by_another_module_reboot_required; return 1; }
    umount "$TARGET" || { err unmount_failed_reboot_required; return 1; }
    rm -f "$STATE/owned"
    return 0
}
restore_props() {
    FAILED=0
    for P in $PROPS; do
        [ -f "$STATE/p.$P.present" ] || { FAILED=1; continue; }
        if [ "$(cat "$STATE/p.$P.present")" = 1 ]; then
            V=$(cat "$STATE/p.$P.value")
            rp -n "$P" "$V" || FAILED=1
            [ "$(getprop "$P")" = "$V" ] || FAILED=1
        else
            # Delete only if present: resetprop can return failure for an absent key.
            if getprop | grep -F "[$P]:" >/dev/null; then rp --delete "$P" || FAILED=1; fi
            if getprop | grep -F "[$P]:" >/dev/null; then FAILED=1; fi
        fi
    done
    [ "$FAILED" = 0 ]
}
disable_mmap() {
    for P in $PROPS; do
        rp -n "$P" 1 || return 1
        [ "$(getprop "$P")" = 1 ] || return 1
    done
}
prepare_patch() {
    detect_target || return 1
    cp "$TARGET" "$STATE/base.xml" || { err snapshot_failed; return 1; }
    # awk validates bounded inputs before printing any replacement content.
    awk -v remove_fast_low="${SOUND_E_FAST:-1}" -v remove_fast_raw="${SOUND_E_FAST_RAW:-1}" -v remove_raw="${SOUND_E_RAW:-1}" -f "$MODDIR/bin/patch_ports.awk" "$STATE/base.xml" > "$STATE/candidate.xml" 2> "$STATE/patch-error.txt" || {
        cat "$STATE/patch-error.txt"
        err unsupported_or_previously_modified_configuration
        return 1
    }
    [ -s "$STATE/candidate.xml" ] || return 1
    cmp -s "$STATE/base.xml" "$STATE/candidate.xml" && { err no_port_changes; return 1; }
    # The target already has the correct vendor-specific SELinux type.
    CTX=$(ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}')
    case "$CTX" in u:object_r:*:s0*) ;; *) err cannot_read_target_selinux_context; return 1 ;; esac
    chmod 0644 "$STATE/candidate.xml" && chown 0:0 "$STATE/candidate.xml" && chcon "$CTX" "$STATE/candidate.xml" || {
        err cannot_prepare_overlay_permissions; return 1
    }
    mv -f "$STATE/candidate.xml" "$STATE/active.xml" || return 1
    printf '%s\n' "$TARGET" > "$STATE/target"
}
install_patch() {
    # No umount here: the original effective mount stays underneath ours.
    touch "$STATE/owned" || return 1
    mount --bind "$STATE/active.xml" "$TARGET" || { rm -f "$STATE/owned"; err bind_mount_denied; return 1; }
    owned_mount || { err mount_not_visible; return 1; }
    cmp -s "$TARGET" "$STATE/active.xml" || { err mount_content_mismatch; return 1; }
}
restart_audio() {
    audio_restart_checked "${1:-${REQUEST:-native}}"
}
native_cleanup() {
    remove_owned_mount || return 1
    restore_props || { err property_restore_failed; return 1; }
    rm -f "$STATE/sound.applied"
    echo native > "$STATE/applied"
}
apply_mode() {
    REQUEST=$1
    case "$REQUEST" in native|compat|sound) ;; *) err bad_mode; return 1 ;; esac
    if [ "$REQUEST" = sound ]; then
        sound_read_config "${SOUND_CONFIG_OVERRIDE:-$MODDIR/sound.conf}" || { err invalid_sound_config; return 1; }
        sound_effective
        log "sound apply request; mmap=$SOUND_E_MMAP fast_low=$SOUND_E_FAST fast_raw=$SOUND_E_FAST_RAW raw=$SOUND_E_RAW"
    fi
    find_resetprop || { err resetprop_missing; return 1; }
    PREVIOUS=$(cat "$STATE/applied" 2>/dev/null)
    NEED_RESTART=0
    [ "$PREVIOUS" = native ] || NEED_RESTART=1
    [ -f "$STATE/transaction" ] && NEED_RESTART=1
    [ -f "$STATE/owned" ] && NEED_RESTART=1
    printf '%s\n' "$REQUEST" > "$STATE/transaction" || return 1
    # Always unwind our previous state first; a failure falls back to native.
    native_cleanup || return 1
    FAIL=0
    if [ "$REQUEST" = sound ] && { [ "$SOUND_E_FAST" = 1 ] || [ "$SOUND_E_FAST_RAW" = 1 ] || [ "$SOUND_E_RAW" = 1 ]; }; then
        if prepare_patch && install_patch; then NEED_RESTART=1; else FAIL=1; fi
    fi
    if { [ "$REQUEST" = compat ] || { [ "$REQUEST" = sound ] && [ "$SOUND_E_MMAP" = 1 ]; }; } && [ "$FAIL" = 0 ]; then
        disable_mmap || FAIL=1
        NEED_RESTART=1
    fi
    if [ "$FAIL" = 0 ] && [ "$NEED_RESTART" = 1 ]; then
        restart_audio || FAIL=1
    fi
    if [ "$FAIL" = 0 ] && [ "$REQUEST" = sound ]; then
        sound_verify_effective || { err sound_readback_failed; FAIL=1; }
        if [ "$FAIL" = 0 ]; then
            printf '%s %s %s %s\n' "$SOUND_E_MMAP" "$SOUND_E_FAST" "$SOUND_E_FAST_RAW" "$SOUND_E_RAW" > "$STATE/sound.applied.new" && \
                mv -f "$STATE/sound.applied.new" "$STATE/sound.applied" || FAIL=1
        fi
    fi
    if [ "$FAIL" != 0 ]; then
        log "apply $REQUEST failed; restoring native"
        if native_cleanup; then
            write_mode native
            # The config may have been consumed before the failure. Restart once,
            # never loop/retry a broken experimental configuration at boot.
            restart_audio native || { err native_restored_but_reboot_required; return 1; }
            rm -f "$STATE/transaction"
            err apply_failed_restored_native
        else
            write_mode native
            err rollback_incomplete_reboot_required
        fi
        return 1
    fi
    printf '%s\n' "$REQUEST" > "$STATE/applied"
    write_mode "$REQUEST" || { err cannot_save_mode; return 1; }
    rm -f "$STATE/transaction"
    log "applied $REQUEST; audio audibility and Dolby not verified"
    echo "ok=1"
    echo "mode=$REQUEST"
    echo "audio_restarted=$NEED_RESTART"
    echo "label=$(name_mode "$REQUEST")"
    echo "请强行停止并重开游戏；状态只表示操作完成，不代表杜比已验证。"
}
status() {
    echo "requested=$(read_mode)"
    echo "applied=$(cat "$STATE/applied" 2>/dev/null)"
    for P in $PROPS; do echo "$P=$(getprop "$P")"; done
    if [ -f "$STATE/owned" ]; then
        if owned_mount; then echo overlay=owned; else echo overlay=conflict; fi
    else echo overlay=none; fi
    echo "audioserver=$(pidof audioserver 2>/dev/null)"
    audio_ready_status
    echo "effect_verified=no"
    boot_status
    [ ! -f "$STATE/transaction" ] || echo "recovery_required=yes (apply native or reboot)"
    return 0
}
. "$MODDIR/bin/sound.sh"
. "$MODDIR/bin/boot.sh"
. "$MODDIR/bin/audio_ready.sh"
