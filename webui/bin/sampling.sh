#!/system/bin/sh
# Read-only diagnostic dispatch. The broker is started by late-start service.sh,
# never by a WebUI shell. Audio mode changes remain in the existing runtime.sh.
valid_target() {
    [ "${#1}" -le 200 ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$'
}
daemon_alive() {
    [ "$(cat "$STATE/diag-daemon.boot" 2>/dev/null)" = "$BOOT_ID" ] || return 1
    DPID=$(cat "$STATE/diag-daemon.pid" 2>/dev/null)
    case "$DPID" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$DPID" 2>/dev/null || return 1
    tr '\000' ' ' < "/proc/$DPID/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/ha.sh diag-daemon" >/dev/null
}
diagnostic_daemon() {
    umask 077
    mkdir -p "$STATE" || return 1
    daemon_alive && return 0
    # service.sh starts this once per boot; a stale directory belongs to a dead broker.
    if ! mkdir "$STATE/diag-daemon.lock" 2>/dev/null; then
        daemon_alive && return 0
        rmdir "$STATE/diag-daemon.lock" 2>/dev/null || return 1
        mkdir "$STATE/diag-daemon.lock" || return 1
    fi
    printf '%s\n' "$$" > "$STATE/diag-daemon.pid"
    printf '%s\n' "$BOOT_ID" > "$STATE/diag-daemon.boot"
    if [ -d "$STATE/diag-queue" ] && [ "$(cat "$STATE/diag-queue/boot" 2>/dev/null)" != "$BOOT_ID" ]; then
        rm -f "$STATE/diag-queue/target" "$STATE/diag-queue/mode" "$STATE/diag-queue/boot"
        rmdir "$STATE/diag-queue" 2>/dev/null
    fi
    trap 'rm -f "$STATE/diag-daemon.pid" "$STATE/diag-daemon.boot"; rmdir "$STATE/diag-daemon.lock" 2>/dev/null' EXIT
    trap 'exit 0' INT TERM HUP
    while [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]; do
        if [ -d "$STATE/diag-pending" ]; then
            QT=$(cat "$STATE/diag-pending/target" 2>/dev/null)
            QM=$(cat "$STATE/diag-pending/mode" 2>/dev/null)
            QB=$(cat "$STATE/diag-pending/boot" 2>/dev/null)
            if [ "$QB" = "$BOOT_ID" ] && valid_target "$QT"; then
                # Child inherits the boot service's process context, not the manager's.
                HA_BUSYBOX=0 /system/bin/sh "$MODDIR/bin/ha.sh" diagnose-target "$QT" "$QM" > "$STATE/diag-job.log" 2>&1
            else
                echo failed > "$STATE/diag-job.state"
            fi
            rm -f "$STATE/diag-pending/target" "$STATE/diag-pending/mode" "$STATE/diag-pending/boot"
            rmdir "$STATE/diag-pending" 2>/dev/null
        fi
        sleep 3
    done
}
queue_diagnostics() {
    valid_target "$1" || { echo error=invalid_package_name; return 1; }
    daemon_alive || { echo 'error=采集后台未运行；请点“启动／重连后台”后重试。'; return 1; }
    if [ -d "$STATE/diag-pending" ] || [ -d "$STATE/diag-queue" ] || diag_pid_alive; then
        echo error=diagnostic_already_running; return 1
    fi
    mkdir "$STATE/diag-queue" || return 1
    if ! { printf '%s\n' "$1" > "$STATE/diag-queue/target" &&
           cat "$STATE/applied" > "$STATE/diag-queue/mode" &&
           printf '%s\n' "$BOOT_ID" > "$STATE/diag-queue/boot"; }; then
        rm -f "$STATE/diag-queue/target" "$STATE/diag-queue/mode" "$STATE/diag-queue/boot"
        rmdir "$STATE/diag-queue" 2>/dev/null
        echo error=cannot_queue_diagnostics; return 1
    fi
    date '+%Y-%m-%dT%H:%M:%S%z' > "$STATE/diag-requested-at"
    printf '%s\n' "$1" > "$STATE/diag-target"
    echo waiting > "$STATE/diag-job.state"
    mv "$STATE/diag-queue" "$STATE/diag-pending" || return 1
    echo ok=1
    echo job=waiting
    echo '请切回目标游戏，保持正在出声或出现电流音的场景约 45 秒。后台最多等待 90 秒。'
}
target_pid_uid() {
    TARGET_PID=""; TARGET_UID=""
    for TP in $(pidof "$DIAG_TARGET" 2>/dev/null); do
        TC=$(tr '\000' '\n' < "/proc/$TP/cmdline" 2>/dev/null | head -n 1)
        [ "$TC" = "$DIAG_TARGET" ] || continue
        TU=$(awk '/^Uid:/ {print $2; exit}' "/proc/$TP/status" 2>/dev/null)
        case "$TU" in ''|*[!0-9]*) continue ;; esac
        TARGET_PID=$TP; TARGET_UID=$TU; return 0
    done
    return 1
}
snapshot_foreground() {
    dumpsys -t 5 activity activities 2>&1 | grep -E 'topResumedActivity|mResumedActivity|ResumedActivity|mFocusedApp'
}
target_is_foreground() {
    grep -F " $DIAG_TARGET/" "$1" >/dev/null
}
target_active_track() {
    # Only current per-thread tables, never Local log / deleted-thread history.
    awk -v uid="$TARGET_UID" '
      /^Output thread / { live=1; table=0 }
      /^  [0-9]+ Tracks of which / && live { table=1; next }
      /^  (WakeLock|Local log|[0-9]+ Effect Chains)/ { table=0 }
      table && !/Type[[:space:]]+Id/ {
        for (i=2;i<NF;i++) if ($i ~ /\/$/ && $(i+1)==uid && $(i-1)=="yes") found=1
      }
      END { exit !found }' "$1"
}
snapshot_context() {
    date '+time=%Y-%m-%dT%H:%M:%S%z'
    echo "mode=$(cat "$STATE/applied" 2>/dev/null)"
    echo "target=$DIAG_TARGET pid=$TARGET_PID uid=$TARGET_UID"
    echo "collector_pid=$$ parent_pid=$PPID"
    cat "/proc/$$/cgroup" 2>/dev/null
    [ -z "$TARGET_PID" ] || cat "/proc/$TARGET_PID/cgroup" 2>/dev/null
}
snapshot_libraries() {
    [ -z "$TARGET_PID" ] || grep -Ei 'libaaudio|libaudio|liboboe|libfmod|libunity|libil2cpp|libsdl|libopenal|dolby|dax' "/proc/$TARGET_PID/maps" 2>/dev/null
}
sample_target() {
    mkdir -p "$D/samples/01"
    SBASE=$D/samples/01
    WAIT_START=$(date +%s)
    # Wait for actual game playback. A timer alone cannot distinguish a suspended
    # manager task from a sample taken with the game still running.
    while :; do
        if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
            SAMPLE_RESULT=module_disabled; return 0
        fi
        if [ "$(cat "$STATE/applied" 2>/dev/null)" != "$DIAG_EXPECTED_MODE" ]; then
            SAMPLE_RESULT=mode_changed; return 0
        fi
        if [ $(( $(date +%s) - WAIT_START )) -ge 90 ]; then
            SAMPLE_RESULT=target_not_active; return 0
        fi
        snapshot_foreground > "$SBASE/foreground-before.txt"
        if target_is_foreground "$SBASE/foreground-before.txt" && target_pid_uid; then
            dumpsys -t 8 media.audio_flinger > "$SBASE/audio_flinger.txt" 2>&1
            snapshot_foreground > "$SBASE/foreground-after.txt"
            if target_is_foreground "$SBASE/foreground-after.txt" && target_active_track "$SBASE/audio_flinger.txt"; then break; fi
        fi
        sleep 2
    done
    snapshot_context > "$SBASE/context.txt"
    snapshot_libraries > "$SBASE/audio-libraries.txt"
    echo target_active=yes > "$SBASE/quality.txt"
    echo collecting > "$STATE/diag-job.state"
    ACTIVE_SAMPLES=1
    logcat -d -t 20000 -v threadtime 2>&1 | grep -Ei 'aaudio|audiotrack|audioflinger|audiopolicy|audio_hw|audioserver|oboe|fmod|dolby|dax|pal_stream|agm_|linker.*(audio|symbol)|avc:.*(audio|vendor_configs)' > "$D/audio-at-first-sample-logcat.txt"
    dumpsys -t 8 media.audio_policy > "$SBASE/audio_policy.txt" 2>&1
    # Keep a short live audio-only log so a noisy system log cannot erase the scene.
    (timeout 25 logcat -v threadtime -T 1 2>&1 | grep -Ei 'aaudio|audiotrack|audioflinger|audiopolicy|audio_hw|audioserver|oboe|fmod|dolby|dax|pal_stream|agm_|linker.*(audio|symbol)|avc:.*(audio|vendor_configs)' > "$D/audio-live-logcat.txt") &
    LIVE_LOG_PID=$!
    for SN in 02 03; do
        sleep 6
        SBASE=$D/samples/$SN
        mkdir "$SBASE"
        target_pid_uid || :
        snapshot_context > "$SBASE/context.txt"
        snapshot_libraries > "$SBASE/audio-libraries.txt"
        snapshot_foreground > "$SBASE/foreground-before.txt"
        dumpsys -t 8 media.audio_flinger > "$SBASE/audio_flinger.txt" 2>&1
        snapshot_foreground > "$SBASE/foreground-after.txt"
        dumpsys -t 8 media.audio_policy > "$SBASE/audio_policy.txt" 2>&1
        if [ -n "$TARGET_UID" ] && target_is_foreground "$SBASE/foreground-before.txt" && target_is_foreground "$SBASE/foreground-after.txt" && target_active_track "$SBASE/audio_flinger.txt" && [ "$(cat "$STATE/applied" 2>/dev/null)" = "$DIAG_EXPECTED_MODE" ]; then
            ACTIVE_SAMPLES=$((ACTIVE_SAMPLES + 1))
            echo target_active=yes > "$SBASE/quality.txt"
        else
            echo target_active=no > "$SBASE/quality.txt"
        fi
    done
    wait "$LIVE_LOG_PID"
    [ "$ACTIVE_SAMPLES" = 3 ] && SAMPLE_RESULT=three_active_samples || SAMPLE_RESULT=partial_samples
    # Top-level dumps refer to the first live sample, not the later return to UI.
    cp "$D/samples/01/foreground-before.txt" "$D/foreground.txt"
    cp "$D/samples/01/audio_flinger.txt" "$D/audio_flinger.txt"
    cp "$D/samples/01/audio_policy.txt" "$D/audio_policy.txt"
}
