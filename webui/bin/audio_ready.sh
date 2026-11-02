#!/system/bin/sh
# Wait for loaded framework configuration, not just a replacement process PID.
# The checks are read-only and never synthesize a playback stream or restart HAL
# or Dolby services separately. They do not certify sound or Dolby processing.
audio_ready_now() { awk '{print int($1)}' /proc/uptime; }
audio_expected_ports() {
    local mode=$1 low=0 raw_fast=0 raw=0
    AUDIO_EXPECT_LOW=""; AUDIO_EXPECT_RAW=""
    : > "$STATE/audio-ready/expected.txt" || return 1
    [ -s "$STATE/base.xml" ] || return 0
    if [ "$mode" = sound ]; then
        low=${SOUND_E_FAST:-1}; raw_fast=${SOUND_E_FAST_RAW:-1}; raw=${SOUND_E_RAW:-1}
    fi
    awk -v remove_fast_low="$low" -v remove_fast_raw="$raw_fast" -v remove_raw="$raw" -v report_flags=1 \
        -f "$MODDIR/bin/patch_ports.awk" "$STATE/base.xml" > "$STATE/audio-ready/expected.txt" 2> "$STATE/audio-ready/reason.txt" || return 1
    AUDIO_EXPECT_LOW=$(sed -n 's/^low_latency_out=//p' "$STATE/audio-ready/expected.txt")
    AUDIO_EXPECT_RAW=$(sed -n 's/^raw_out=//p' "$STATE/audio-ready/expected.txt")
}
audio_ready_probe() {
    local pid=$1
    [ "$(getprop init.svc.audioserver)" = running ] || { echo audioserver_not_running > "$STATE/audio-ready/reason.txt"; return 1; }
    dumpsys -t 2 media.audio_policy > "$STATE/audio-ready/policy.txt" 2>&1 || {
        echo audio_policy_unavailable > "$STATE/audio-ready/reason.txt"; return 1;
    }
    dumpsys -t 2 media.audio_flinger > "$STATE/audio-ready/flinger.txt" 2>&1 || {
        echo audio_flinger_unavailable > "$STATE/audio-ready/reason.txt"; return 1;
    }
    [ "$(pidof audioserver 2>/dev/null)" = "$pid" ] || { echo audioserver_changed_during_probe > "$STATE/audio-ready/reason.txt"; return 1; }
    awk -v expected_low="$AUDIO_EXPECT_LOW" -v expected_raw="$AUDIO_EXPECT_RAW" \
        -f "$MODDIR/bin/check_audio_ready.awk" "$STATE/audio-ready/policy.txt" "$STATE/audio-ready/flinger.txt" \
        > "$STATE/audio-ready/observed.txt" 2> "$STATE/audio-ready/reason.txt"
}
audio_ready_failure_snapshot() {
    local file
    mkdir -p "$STATE/audio-ready-failure" || return 0
    for file in expected.txt policy.txt flinger.txt observed.txt reason.txt result.txt context.txt; do
        if [ -f "$STATE/audio-ready/$file" ]; then cp "$STATE/audio-ready/$file" "$STATE/audio-ready-failure/$file"; fi
    done
}
audio_restart_checked() {
    local mode=${1:-native} old_pid new_pid last_pid="" last_signature="" signature stable=0 attempts=0 start now
    old_pid=$(pidof audioserver 2>/dev/null)
    [ -n "$old_pid" ] || { err audioserver_not_running; return 1; }
    mkdir -p "$STATE/audio-ready" || { err audio_ready_state_unavailable; return 1; }
    rm -f "$STATE/audio-ready/pid" "$STATE/audio-ready/boot" "$STATE/audio-ready/policy.txt" "$STATE/audio-ready/flinger.txt" "$STATE/audio-ready/observed.txt"
    echo waiting > "$STATE/audio-ready/result.txt"
    { date '+check_started=%Y-%m-%dT%H:%M:%S%z'; echo "boot=$BOOT_ID"; echo "requested=$mode"; } > "$STATE/audio-ready/context.txt"
    audio_expected_ports "$mode" || { err audio_ready_expected_flags_failed; return 1; }
    start=$(audio_ready_now) || return 1
    setprop ctl.restart audioserver || { err audioserver_restart_denied; return 1; }
    # Both monotonic elapsed time and an attempt cap bound recovery. The same
    # new PID, primary output and loaded port flags must pass three probes.
    while [ "$attempts" -lt 20 ]; do
        now=$(audio_ready_now) || return 1
        [ $((now-start)) -lt 30 ] || break
        attempts=$((attempts+1))
        new_pid=$(pidof audioserver 2>/dev/null)
        if [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && audio_ready_probe "$new_pid"; then
            signature=$(cat "$STATE/audio-ready/observed.txt")
            if [ "$new_pid" = "$last_pid" ] && [ "$signature" = "$last_signature" ]; then stable=$((stable+1)); else stable=1; fi
            last_pid=$new_pid; last_signature=$signature
            if [ "$stable" -ge 3 ]; then
                printf '%s\n' "$new_pid" > "$STATE/audio-ready/pid" && \
                printf '%s\n' "$BOOT_ID" > "$STATE/audio-ready/boot" && \
                echo framework_ready > "$STATE/audio-ready/result.txt" || return 1
                log "audio framework ready; pid=$new_pid probes=$attempts; loaded port flags checked; playback/Dolby not verified"
                return 0
            fi
        else
            stable=0; last_pid=""; last_signature=""
            [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] || echo audioserver_pid_not_replaced > "$STATE/audio-ready/reason.txt"
        fi
        sleep 1
    done
    echo failed > "$STATE/audio-ready/result.txt"
    audio_ready_failure_snapshot
    log "audio readiness failed; mode=$mode reason=$(cat "$STATE/audio-ready/reason.txt" 2>/dev/null)"
    err audio_framework_not_ready
}
audio_ready_status() {
    if [ "$(cat "$STATE/audio-ready/boot" 2>/dev/null)" = "$BOOT_ID" ] && \
       [ "$(cat "$STATE/audio-ready/pid" 2>/dev/null)" = "$(pidof audioserver 2>/dev/null)" ] && \
       [ "$(cat "$STATE/audio-ready/result.txt" 2>/dev/null)" = framework_ready ]; then
        echo audio_ready_check=passed
    else echo audio_ready_check=unverified; fi
}
