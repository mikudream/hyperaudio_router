#!/system/bin/sh
# Sound-only preferences are data. Never source a user-writable config file.
sound_defaults() { SOUND_CUSTOM=0; SOUND_MMAP=1; SOUND_FAST=1; SOUND_FAST_RAW=1; SOUND_RAW=1; }
sound_read_config() {
    sound_defaults
    local file=${1:-$MODDIR/sound.conf} values
    [ -f "$file" ] || return 0
    values=$(awk -F= '
        $0 !~ /^(custom|mmap|fast|fast_raw|raw)=[01]$/ {bad=1}
        {if (++seen[$1]>1) bad=1; v[$1]=$2}
        END {if(bad || !seen["custom"] || !seen["mmap"] || !seen["fast"] || !seen["raw"]) exit 1;
             if(NR==4 && !seen["fast_raw"]) v["fast_raw"]=v["fast"];
             else if(NR!=5 || !seen["fast_raw"]) exit 1;
             print v["custom"],v["mmap"],v["fast"],v["fast_raw"],v["raw"]}' "$file") || return 1
    # Legacy fast applies to both ports; the new fast key controls low_latency_out only.
    read -r SOUND_CUSTOM SOUND_MMAP SOUND_FAST SOUND_FAST_RAW SOUND_RAW <<EOF
$values
EOF
}
sound_effective() {
    SOUND_E_MMAP=1; SOUND_E_FAST=1; SOUND_E_FAST_RAW=1; SOUND_E_RAW=1
    if [ "$SOUND_CUSTOM" = 1 ]; then
        SOUND_E_MMAP=$SOUND_MMAP; SOUND_E_FAST=$SOUND_FAST; SOUND_E_FAST_RAW=$SOUND_FAST_RAW; SOUND_E_RAW=$SOUND_RAW
    fi
}
sound_original_props_match() {
    local p present value
    for p in $PROPS; do
        present=$(cat "$STATE/p.$p.present" 2>/dev/null)
        case "$present" in
            1)
                value=$(cat "$STATE/p.$p.value" 2>/dev/null) || return 1
                getprop | grep -F "[$p]:" >/dev/null || return 1
                [ "$(getprop "$p")" = "$value" ] || return 1 ;;
            0) if getprop | grep -F "[$p]:" >/dev/null; then return 1; fi ;;
            *) return 1 ;;
        esac
    done
}
sound_verify_effective() {
    local p
    if [ "$SOUND_E_MMAP" = 1 ]; then
        for p in $PROPS; do [ "$(getprop "$p")" = 1 ] || return 1; done
    else
        sound_original_props_match || return 1
    fi
    if [ "$SOUND_E_FAST" = 1 ] || [ "$SOUND_E_FAST_RAW" = 1 ] || [ "$SOUND_E_RAW" = 1 ]; then
        owned_mount || return 1
        [ -s "$STATE/base.xml" ] && cmp -s "$TARGET" "$STATE/active.xml" || return 1
        # Re-create the expected flags from the baseline, not from a claimed marker.
        awk -v remove_fast_low="$SOUND_E_FAST" -v remove_fast_raw="$SOUND_E_FAST_RAW" -v remove_raw="$SOUND_E_RAW" \
            -f "$MODDIR/bin/patch_ports.awk" "$STATE/base.xml" 2>/dev/null | cmp -s - "$TARGET" || return 1
    else
        [ ! -f "$STATE/owned" ] || return 1
    fi
}
sound_status() {
    local valid=1 state=saved applied
    if sound_read_config; then
        if [ -f "$MODDIR/sound.conf" ]; then echo sound_config=saved; else echo sound_config=defaults; fi
    else echo sound_config=invalid; valid=0; fi
    sound_effective
    printf 'sound_custom=%s\nsound_mmap=%s\nsound_fast=%s\nsound_fast_raw=%s\nsound_raw=%s\n' \
        "$SOUND_CUSTOM" "$SOUND_MMAP" "$SOUND_FAST" "$SOUND_FAST_RAW" "$SOUND_RAW"
    if [ "$valid" = 0 ]; then state=invalid
    elif [ -f "$STATE/transaction" ]; then state=recovery_required
    elif [ "$(cat "$STATE/applied" 2>/dev/null)" = sound ]; then
        applied=$(cat "$STATE/sound.applied" 2>/dev/null)
        state=mismatch
        if [ "$(cat "$STATE/boot" 2>/dev/null)" = "$BOOT_ID" ] && \
           [ "$applied" = "$SOUND_E_MMAP $SOUND_E_FAST $SOUND_E_FAST_RAW $SOUND_E_RAW" ] && sound_verify_effective; then state=applied; fi
    fi
    echo "sound_state=$state"
}
sound_save() {
    # Retain the old four-Boolean CLI: its FAST choice still controls both ports.
    if [ "$#" = 4 ]; then set -- "$1" "$2" "$3" "$3" "$4"; fi
    [ "$#" = 5 ] || { echo error=bad_sound_arguments; return 1; }
    local arg rc=0 paused=0
    for arg in "$@"; do case "$arg" in 0|1) ;; *) echo error=bad_sound_arguments; return 1 ;; esac; done
    # A complete candidate is validated/applied before it replaces the saved file.
    printf 'custom=%s\nmmap=%s\nfast=%s\nfast_raw=%s\nraw=%s\n' "$1" "$2" "$3" "$4" "$5" > "$MODDIR/sound.conf.new" || { err sound_config_prepare_failed; return 1; }
    chmod 0600 "$MODDIR/sound.conf.new" || { rm -f "$MODDIR/sound.conf.new"; err sound_config_prepare_failed; return 1; }
    if [ "$(cat "$STATE/applied" 2>/dev/null)" = sound ]; then
        if ! ll_pause; then rm -f "$MODDIR/sound.conf.new"; return 1; fi
        paused=1
        SOUND_CONFIG_OVERRIDE=$MODDIR/sound.conf.new
        apply_mode sound; rc=$?
        unset SOUND_CONFIG_OVERRIDE
        if [ "$rc" != 0 ]; then
            rm -f "$MODDIR/sound.conf.new"
            if [ "$paused" = 1 ] && [ ! -f "$STATE/transaction" ]; then ll_resume; fi
            return "$rc"
        fi
    fi
    if ! mv -f "$MODDIR/sound.conf.new" "$MODDIR/sound.conf"; then
        rm -f "$MODDIR/sound.conf.new"
        # The route cannot claim saved parameters if committing the file failed.
        if [ "$(cat "$STATE/applied" 2>/dev/null)" = sound ]; then
            if apply_mode native; then err sound_config_save_failed_restored_native
            else err sound_config_save_failed_reboot_required; fi
        else err sound_config_save_failed; fi
        if [ "$paused" = 1 ] && [ ! -f "$STATE/transaction" ]; then ll_resume; fi
        return 1
    fi
    if [ "$paused" = 1 ] && [ ! -f "$STATE/transaction" ]; then ll_resume; fi
    log "saved sound preferences; custom=$1 mmap=$2 fast_low=$3 fast_raw=$4 raw=$5"
    echo sound_saved=1
    sound_status
}
sound_reset() { sound_save 0 1 1 1 1; }
