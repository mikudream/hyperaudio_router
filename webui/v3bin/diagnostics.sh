#!/system/bin/sh
# Read-only audio observations. Writes only report/state files; no resets or patches.
diag_pid_alive() {
    [ "$(cat "$STATE/diag-job.boot" 2>/dev/null)" = "$BOOT_ID" ] || return 1
    DP=$(cat "$STATE/diag-job.pid" 2>/dev/null)
    case "$DP" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$DP" 2>/dev/null || return 1
    tr '\000' ' ' < "/proc/$DP/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/ha.sh" >/dev/null
}
diag_status() {
    JS=$(cat "$STATE/diag-job.state" 2>/dev/null)
    case "$JS" in waiting|collecting)
        if ! diag_pid_alive; then
            [ -d "$STATE/diag-pending" ] && daemon_alive || JS=stopped
        fi ;;
        done|failed|incomplete) ;; *) JS=idle ;;
    esac
    echo "job=$JS"
    echo "daemon=$(daemon_alive && echo ready || echo offline)"
    echo "quality=$(cat "$STATE/diag-last-quality" 2>/dev/null)"
    echo "target=$(cat "$STATE/diag-target" 2>/dev/null)"
    echo "report=$(cat "$STATE/diag-last-report" 2>/dev/null)"
    [ ! -f "$STATE/diag-last-report" ] || echo "report_mode=$(cat "$STATE/diag-last-mode" 2>/dev/null)"
    return 0
}
diag_copy_config() {
    CF=$1
    [ -f "$CF" ] || return 0
    case "$CF" in /odm/etc/*|/vendor/etc/*|/system/etc/*|/system_ext/etc/*) ;; *) return 0 ;; esac
    CS=$(stat -c %s "$CF" 2>/dev/null)
    case "$CS" in ''|*[!0-9]*) return 0 ;; esac
    # Only small text configuration files, never calibration/firmware binaries.
    [ "$CS" -le 4194304 ] || { echo "skipped oversized: $CF" >> "$D/config-manifest.txt"; return 0; }
    REL=${CF#/}
    mkdir -p "$D/configs/${REL%/*}" || return 1
    cp "$CF" "$D/configs/$REL" || return 1
    sha256sum "$CF" >> "$D/config-manifest.txt" 2>/dev/null
}
detect_tuning() {
    TN=0
    for TD in /data/adb/modules/*; do
        [ -f "$TD/module.prop" ] || continue
        [ ! -f "$TD/disable" ] && [ ! -f "$TD/remove" ] || continue
        case "${TD##*/}" in hyperaudio|hyperaudio_compat) continue ;; esac
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
collect_diagnostics() {
    DEST=/sdcard/Download
    [ -d "$DEST" ] || { echo error=download_directory_missing; return 1; }
    DMODE=$(cat "$STATE/applied" 2>/dev/null)
    case "$DMODE" in native|compat|sound) ;; *) DMODE=unknown ;; esac
    DTAG=$(date '+%Y%m%d-%H%M%S')-$$
    D=$STATE/diag-$DTAG
    mkdir "$D" || return 1
    status > "$D/status-before.txt"
    cp "$MODDIR/module.prop" "$D/module.prop"
    ll_status > "$D/lowlat-status.txt"
    cp "$MODDIR/lowlat.conf" "$D/lowlat.conf"
    [ ! -f "$MODDIR/sound.conf" ] || cp "$MODDIR/sound.conf" "$D/sound.conf"
    for READY_DIR in audio-ready audio-ready-failure; do
        [ ! -d "$STATE/$READY_DIR" ] || cp -R "$STATE/$READY_DIR" "$D/$READY_DIR"
    done
    [ ! -f "$MODDIR/boot.conf" ] || cp "$MODDIR/boot.conf" "$D/boot.conf"
    boot_status > "$D/boot-status.txt"
    [ ! -f "$LLROOT/details" ] || cp "$LLROOT/details" "$D/lowlat-details.txt"
    [ ! -f "$LLROOT/restore.log" ] || cp "$LLROOT/restore.log" "$D/lowlat-restore.txt"
    {
        date '+capture_start=%Y-%m-%dT%H:%M:%S%z'
        echo "label_mode=$DMODE"
        echo "capture_namespace=$(readlink /proc/self/ns/mnt)"
        echo "init_namespace=$(readlink /proc/1/ns/mnt)"
        for P in ro.product.device ro.build.version.release ro.build.version.sdk ro.build.version.incremental ro.build.fingerprint; do
            echo "$P=$(getprop "$P")"
        done
        getprop | grep -Ei 'aaudio|audio[._]|dolby|misound'
    } > "$D/audio-properties.txt"
    SAMPLE_RESULT=system_snapshot
    ACTIVE_SAMPLES=0
    if [ -n "$DIAG_TARGET" ]; then sample_target; fi
    [ -s "$D/foreground.txt" ] || snapshot_foreground > "$D/foreground.txt"
    [ -s "$D/audio_flinger.txt" ] || dumpsys -t 8 media.audio_flinger > "$D/audio_flinger.txt" 2>&1
    [ -s "$D/audio_policy.txt" ] || dumpsys -t 8 media.audio_policy > "$D/audio_policy.txt" 2>&1
    dumpsys -t 8 media.aaudio > "$D/aaudio.txt" 2>&1
    dumpsys -t 8 audio > "$D/audio_service.txt" 2>&1
    logcat -d -t 4000 -v threadtime 2>&1 | grep -Ei 'aaudio|audiotrack|audioflinger|audiopolicy|audio_hw|audioserver|oboe|fmod|dolby|dax|pal_stream|agm_|linker.*(audio|symbol)|avc:.*(audio|vendor_configs)' > "$D/audio-logcat.txt"
    if [ -x /system/bin/ps ]; then /system/bin/ps -A; else ps -A; fi > "$D/processes.tmp" 2>&1
    grep -Ei '(^USER|audio|dolby|dax)' "$D/processes.tmp" > "$D/audio-processes.txt"
    FGPACKAGES=$(grep -oE '[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+' "$D/foreground.txt" | cut -d/ -f1 | sort -u)
    for FG in $FGPACKAGES $DIAG_TARGET; do grep -F "$FG" "$D/processes.tmp" >> "$D/audio-processes.txt"; done
    APIDS=$(awk '$2 ~ /^[0-9]+$/ {print $2}' "$D/audio-processes.txt" | sort -u)
    rm -f "$D/processes.tmp"
    for AP in $APIDS; do
        {
            echo "pid=$AP namespace=$(readlink "/proc/$AP/ns/mnt")"
            tr '\000' ' ' < "/proc/$AP/cmdline"; echo
            grep -Ei 'libaaudio|dolby|dax|misound|libaudio.*impl' "/proc/$AP/maps"
        } > "$D/audio-process-$AP.txt" 2>&1
    done
    # All live audio policy/effect/mixer text configs, including nested include files.
    for CD in /odm/etc/audio /vendor/etc/audio /odm/etc/dolby /vendor/etc/dolby; do
        [ -d "$CD" ] || continue
        find "$CD" -maxdepth 4 -type f \( -name '*.xml' -o -name '*.json' \) -print 2>/dev/null | while IFS= read -r CF; do
            diag_copy_config "$CF"
        done
    done
    for CD in /odm/etc /vendor/etc /system/etc /system_ext/etc; do
        [ -d "$CD" ] || continue
        find "$CD" -maxdepth 1 -type f \( -name '*audio*.xml' -o -name '*audio*.json' -o -name 'mixer_paths*.xml' \) -print 2>/dev/null | while IFS= read -r CF; do
            diag_copy_config "$CF"
        done
    done
    detect_tuning > "$D/tuning-candidates.txt"
    {
        for ML in /data/adb/modules/*/module.prop; do
            [ -f "$ML" ] || continue
            MD=${ML%/module.prop}
            echo "module=${MD##*/} disabled=$([ -f "$MD/disable" ] && echo yes || echo no)"
            sed -n '/^id=/p;/^name=/p;/^version=/p' "$ML"
        done
    } > "$D/modules.txt"
    {
        for LF in /system/lib64/libaaudio*.so; do
            [ -f "$LF" ] || continue
            ls -lZ "$LF"
            sha256sum "$LF"
        done
    } > "$D/aaudio-library-identities.txt" 2>&1
    for SF in events.log patch-error.txt base.xml active.xml diag-job.log; do
        [ ! -f "$STATE/$SF" ] || cp "$STATE/$SF" "$D/$SF"
    done
    [ ! -f "$MODDIR/last_boot.log" ] || cp "$MODDIR/last_boot.log" "$D/last_boot.log"
    grep -E 'audio|hyperaudio_compat' /proc/self/mountinfo > "$D/audio-mounts.txt"
    status > "$D/status-after.txt"
    {
        date '+capture_end=%Y-%m-%dT%H:%M:%S%z'
        AFTER_MODE=$(cat "$STATE/applied" 2>/dev/null)
        echo "mode_after=$AFTER_MODE"
        [ "$AFTER_MODE" = "$DMODE" ] || echo 'WARNING: mode changed during capture; do not treat as a stable A/B sample.'
    } >> "$D/audio-properties.txt"
    [ -f "$STATE/diag-requested-at" ] && cp "$STATE/diag-requested-at" "$D/requested-at.txt"
    [ "$(cat "$STATE/applied" 2>/dev/null)" = "$DMODE" ] || SAMPLE_RESULT=mode_changed
    {
        echo "result=$SAMPLE_RESULT"
        echo "target=$DIAG_TARGET"
        echo "expected_mode=$DIAG_EXPECTED_MODE"
        echo "active_samples=$ACTIVE_SAMPLES"
        echo 'Each sample has separate timestamps, foreground checks, and track state.'
        echo 'An active sample does not prove Dolby processing or audible sound.'
    } > "$D/capture-quality.txt"
    debug_analyze_dir "$D" > "$D/analysis.txt"
    ARCHIVE=$STATE/diag-$DTAG.tar.gz
    tar -czf "$ARCHIVE" -C "$D" . || return 1
    OUT=$DEST/hyperaudio-$DMODE-$DTAG.tar.gz
    cp "$ARCHIVE" "$OUT.part" && mv "$OUT.part" "$OUT" || return 1
    chmod 0644 "$OUT"
    { printf '报告：hyperaudio-%s-%s.tar.gz\n' "$DMODE" "$DTAG"; cat "$D/analysis.txt"; } > "$STATE/debug-last-analysis.$$.tmp"
    mv "$STATE/debug-last-analysis.$$.tmp" "$STATE/debug-last-analysis.txt"
    printf '%s\n' "$OUT" > "$STATE/diag-last-report"
    printf '%s\n' "$DMODE" > "$STATE/diag-last-mode"
    printf '%s\n' "$SAMPLE_RESULT" > "$STATE/diag-last-quality"
    rm -rf "$D"
    rm -f "$ARCHIVE"
    echo "ok=1"
    echo "diagnostics=$OUT"
    echo "含音频配置、包名、进程/模块信息；未自动上传。"
}
run_diagnostics() {
    umask 077
    mkdir -p "$STATE" || return 1
    if ! mkdir "$STATE/diag-lock" 2>/dev/null; then
        DP=$(cat "$STATE/diag-lock/pid" 2>/dev/null)
        case "$DP" in ''|*[!0-9]*) echo error=diagnostic_lock_incomplete_reboot_or_retry; return 1 ;; esac
        if [ "$(cat "$STATE/diag-lock/boot" 2>/dev/null)" = "$BOOT_ID" ] && kill -0 "$DP" 2>/dev/null; then
            echo error=diagnostic_already_running; return 1
        fi
        rm -f "$STATE/diag-lock/pid" "$STATE/diag-lock/boot"
        rmdir "$STATE/diag-lock" && mkdir "$STATE/diag-lock" || return 1
    fi
    printf '%s\n' "$$" > "$STATE/diag-lock/pid"
    printf '%s\n' "$BOOT_ID" > "$STATE/diag-lock/boot"
    trap 'rm -f "$STATE/diag-lock/pid" "$STATE/diag-lock/boot"; rmdir "$STATE/diag-lock" 2>/dev/null' EXIT
    trap 'echo failed > "$STATE/diag-job.state"; exit 130' INT TERM HUP
    printf '%s\n' "$$" > "$STATE/diag-job.pid"
    printf '%s\n' "$BOOT_ID" > "$STATE/diag-job.boot"
    if [ -n "$DIAG_TARGET" ]; then echo waiting; else echo collecting; fi > "$STATE/diag-job.state"
    if collect_diagnostics; then
        case "$SAMPLE_RESULT" in three_active_samples|system_snapshot) echo done ;; *) echo incomplete ;; esac > "$STATE/diag-job.state"
        return 0
    fi
    echo failed > "$STATE/diag-job.state"
    echo error=diagnostic_capture_failed
    return 1
}
