#!/system/bin/sh
# Verified scheduling only. No library replacement, global audio properties,
# cgroup edits, persistent RT limits, or changes to arbitrary game main threads.
LLROOT=$STATE/lowlat
ll_init() {
    mkdir -p "$LLROOT/owned" || return 1
    if [ "$(cat "$LLROOT/boot" 2>/dev/null)" != "$BOOT_ID" ]; then
        rm -f "$LLROOT/lock/pid"
        rmdir "$LLROOT/lock" 2>/dev/null
        rm -f "$LLROOT"/owned/* "$LLROOT/status" "$LLROOT/proof" "$LLROOT/details" "$LLROOT/daemon.pid"
        printf '%s\n' "$BOOT_ID" > "$LLROOT/boot"
    fi
}
ll_read_config() {
    LL_ENABLED=1; LL_HAL=20; LL_AUDIO=16; LL_APP=15; LL_REV=initial
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
          enabled) LL_ENABLED=$v ;;
          hal_priority) LL_HAL=$v ;; audio_priority) LL_AUDIO=$v ;; app_priority) LL_APP=$v ;;
          revision) LL_REV=$v ;;
        esac
    done < "$MODDIR/lowlat.conf"
    ll_valid "$LL_ENABLED" "$LL_HAL" "$LL_AUDIO" "$LL_APP"
}
ll_valid() {
    # 4 个参数：enabled、hal、audio、app（白名单已移除）
    [ "$#" = 4 ] || return 1
    case "$1" in 0|1) ;; *) return 1 ;; esac
    local p
    for p in "$2" "$3" "$4"; do
        case "$p" in ''|*[!0-9]*|0*) return 1 ;; esac
        [ "${#p}" -le 2 ] && [ "$p" -ge 1 ] && [ "$p" -le 99 ] || return 1
    done
}
ll_lock() {
    local n=0 owner
    while ! mkdir "$LLROOT/lock" 2>/dev/null; do
        owner=$(cat "$LLROOT/lock/pid" 2>/dev/null)
        case "$owner" in ''|*[!0-9]*) ;; *)
            if ! kill -0 "$owner" 2>/dev/null; then
                rm -f "$LLROOT/lock/pid"; rmdir "$LLROOT/lock" 2>/dev/null; continue
            fi ;;
        esac
        if [ "$n" -ge 2 ] && [ ! -f "$LLROOT/lock/pid" ]; then
            rmdir "$LLROOT/lock" 2>/dev/null
        fi
        n=$((n+1)); [ "$n" -le 12 ] || return 1
        sleep 1
    done
    echo $$ > "$LLROOT/lock/pid"
}
ll_unlock() { rm -f "$LLROOT/lock/pid"; rmdir "$LLROOT/lock" 2>/dev/null; }
ll_stat() {
    # Fields after the LAST ') ' begin at field 3. comm may contain spaces/parentheses.
    local s
    IFS= read -r s < "/proc/$1/task/$2/stat" 2>/dev/null || return 1
    s=${s##*) }
    set -- $s
    [ "$#" -ge 39 ] || return 1
    shift 19; LL_START=$1; shift 18; LL_PRIO=$1; shift; LL_POLICY=$1
    case "$LL_START:$LL_PRIO:$LL_POLICY" in *[!0-9:]*) return 1 ;; esac
}
ll_chrt() {
    local flag
    case "$2" in 0) flag=-o ;; 1) flag=-f ;; 2) flag=-r ;; *) return 1 ;; esac
    chrt "$flag" -p "$3" "$1"
}
ll_restore_file() {
    local f=$1 p t start op orp previous pending group
    read -r p t start op orp previous pending group < "$f" || return 1
    if ! ll_stat "$p" "$t" || [ "$LL_START" != "$start" ]; then rm -f "$f"; return 0; fi
    if [ "$LL_POLICY:$LL_PRIO" = "$op:$orp" ]; then rm -f "$f"; return 0; fi
    # Do not overwrite a policy subsequently assigned by Android or another tool.
    if [ "$LL_POLICY" != 1 ] || { [ "$LL_PRIO" != "$previous" ] && [ "$LL_PRIO" != "$pending" ]; }; then
        echo "restore_external_owner tid=$t actual=$LL_POLICY/$LL_PRIO" >> "$LLROOT/restore.log"
        rm -f "$f"; return 0
    fi
    ll_chrt "$t" "$op" "$orp" >> "$LLROOT/restore.log" 2>&1 || return 1
    ll_stat "$p" "$t" || { rm -f "$f"; return 0; }
    [ "$LL_START" = "$start" ] || { rm -f "$f"; return 0; }
    [ "$LL_POLICY:$LL_PRIO" = "$op:$orp" ] || return 1
    rm -f "$f"
}
ll_restore_all() {
    local f failed=0
    for f in "$LLROOT"/owned/*; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *[!0-9]*) continue ;; esac
        ll_restore_file "$f" || failed=$((failed+1))
    done
    [ "$failed" = 0 ]
}
ll_state() {
    {
        echo "ll_state=$1"; echo "ll_verified=${LL_OK:-0}"; echo "ll_failed=${LL_FAIL:-0}"
        echo "ll_hal=${LL_HOK:-0}"; echo "ll_audio=${LL_AOK:-0}"; echo "ll_app=${LL_POK:-0}"
        echo "ll_revision=$LL_REV"; echo "ll_time=$(date '+%m-%d %H:%M:%S')"
        echo "ll_packages=${LL_PACKAGES:-}"; echo "ll_reason=${2:-}"
    } > "$LLROOT/status.new"
    mv "$LLROOT/status.new" "$LLROOT/status"
}
ll_add_threads() {
    local p=$1 group=$2 priority=$3 td name match
    case "$p" in ''|*[!0-9]*) return ;; esac
    for td in /proc/"$p"/task/[0-9]*; do
        [ -d "$td" ] || continue
        IFS= read -r name < "$td/comm" 2>/dev/null || continue
        match=0
        case "$group:$name" in
          # 端口名式（AOSP 系）与厂商线程名（AudioOut_*/agm_*/DAP*）都算 HAL 组
          hal:low_latency*|hal:raw_out*|hal:mmap_no_irq*|hal:deep_buffer*|hal:AudioOut_*|hal:AudioIn_*|hal:out_*|hal:agm_*|hal:DAP*) match=1 ;;
          audio:FastMixer*|audio:AudioOut_*|audio:AudioMix*|audio:AAudio_*) match=1 ;;
          app:AudioTrack*|app:AAudio_*|app:FMOD\ mixer*|app:FMOD\ stream*|app:Audio\ Mixer*|app:UnityAudio*) match=1 ;;
        esac
        [ "$match" = 1 ] && printf '%s %s %s %s\n' "$p" "${td##*/}" "$group" "$priority"
    done
}
ll_targets() {
    local p pkg uid any=0
    LL_PACKAGES=""
    : > "$LLROOT/wanted"
    dumpsys -t 5 media.audio_flinger > "$LLROOT/flinger" 2>/dev/null || return 1
    awk -f "$MODDIR/bin/active_clients.awk" "$LLROOT/flinger" > "$LLROOT/clients"
    while read -r p; do
        uid=$(awk '/^Uid:/ {print $2; exit}' "/proc/$p/status" 2>/dev/null)
        case "$uid" in ''|*[!0-9]*) continue ;; esac
        [ "$uid" -ge 10000 ] || continue
        pkg=$(tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -n 1)
        pkg=${pkg%%:*}
        valid_target "$pkg" || continue
        
        any=1; LL_PACKAGES="$LL_PACKAGES $pkg"
        ll_add_threads "$p" app "$LL_APP" >> "$LLROOT/wanted"
    done < "$LLROOT/clients"
    [ "$any" = 1 ] || return 0
    for p in $(pidof audioserver 2>/dev/null); do ll_add_threads "$p" audio "$LL_AUDIO" >> "$LLROOT/wanted"; done
    for p in $(pidof audiohalservice.qti android.hardware.audio.service android.hardware.audio.service-aidl 2>/dev/null); do
        ll_add_threads "$p" hal "$LL_HAL" >> "$LLROOT/wanted"
    done
    sort -u "$LLROOT/wanted" > "$LLROOT/wanted.new" && mv "$LLROOT/wanted.new" "$LLROOT/wanted"
}
ll_apply_one() {
    local p=$1 t=$2 group=$3 priority=$4 start op orp previous pending oldgroup rp rt f
    f=$LLROOT/owned/$t
    ll_stat "$p" "$t" || return 1
    start=$LL_START; op=$LL_POLICY; orp=$LL_PRIO; previous=$priority
    if [ -f "$f" ]; then
        read -r rp rt start op orp previous pending oldgroup < "$f" || return 1
        if [ "$rp" != "$p" ] || [ "$LL_START" != "$start" ]; then
            rm -f "$f"; start=$LL_START; op=$LL_POLICY; orp=$LL_PRIO; previous=$priority
        elif [ "$LL_POLICY" != 1 ] || { [ "$LL_PRIO" != "$previous" ] && [ "$LL_PRIO" != "$pending" ]; }; then
            echo "conflict tid=$t group=$group actual=$LL_POLICY/$LL_PRIO" >> "$LLROOT/details.new"
            return 1
        fi
    fi
    case "$op" in 0|1|2) ;; *)
        echo "unsupported_policy tid=$t group=$group policy=$op" >> "$LLROOT/details.new"; return 1 ;;
    esac
    # Write-ahead journal preserves the pre-module state across live edits/crashes.
    printf '%s %s %s %s %s %s %s %s\n' "$p" "$t" "$start" "$op" "$orp" "$previous" "$priority" "$group" > "$f.new" && mv "$f.new" "$f" || return 1
    if [ "$LL_POLICY:$LL_PRIO" != "1:$priority" ]; then
        if ! ll_chrt "$t" 1 "$priority" > "$LLROOT/last-error" 2>&1; then
            echo "denied tid=$t group=$group requested=$priority $(cat "$LLROOT/last-error")" >> "$LLROOT/details.new"
            ll_restore_file "$f" || :
            return 1
        fi
    fi
    ll_stat "$p" "$t" || return 1
    if [ "$LL_START:$LL_POLICY:$LL_PRIO" != "$start:1:$priority" ]; then
        echo "mismatch tid=$t group=$group requested=$priority actual=$LL_POLICY/$LL_PRIO" >> "$LLROOT/details.new"
        return 1
    fi
    printf '%s %s %s %s %s %s %s %s\n' "$p" "$t" "$start" "$op" "$orp" "$priority" "$priority" "$group" > "$f.new" && mv "$f.new" "$f" || return 1
    echo "verified tid=$t group=$group requested=$priority actual=FIFO/$LL_PRIO" >> "$LLROOT/details.new"
    case "$group" in hal) LL_HOK=$((LL_HOK+1));; audio) LL_AOK=$((LL_AOK+1));; app) LL_POK=$((LL_POK+1));; esac
}
ll_tick_locked() {
    local f t p group priority result
    LL_OK=0; LL_FAIL=0; LL_HOK=0; LL_AOK=0; LL_POK=0; LL_PACKAGES=""
    ll_read_config || { ll_restore_all; ll_state error invalid_config; return 1; }
    if [ "$LL_ENABLED" != 1 ] || [ "$(cat "$STATE/applied" 2>/dev/null)" != native ] || [ -f "$LLROOT/pause" ]; then
        : > "$LLROOT/details"
        ll_restore_all || { ll_state error restore_failed; return 1; }
        if [ "$LL_ENABLED" = 1 ]; then ll_state suspended; else ll_state off; fi
        return 0
    fi
    if ! ll_targets; then
        if ll_restore_all; then ll_state error audio_snapshot_failed; else ll_state error restore_failed; fi
        return 1
    fi
    : > "$LLROOT/details.new"
    for f in "$LLROOT"/owned/*; do
        [ -f "$f" ] || continue
        t=${f##*/}
        case "$t" in *[!0-9]*) continue ;; esac
        if ! awk -v t="$t" '$2==t {found=1} END {exit !found}' "$LLROOT/wanted"; then
            ll_restore_file "$f" || LL_FAIL=$((LL_FAIL+1))
        fi
    done
    while read -r p t group priority; do
        [ -n "$t" ] || continue
        if ll_apply_one "$p" "$t" "$group" "$priority"; then LL_OK=$((LL_OK+1)); else LL_FAIL=$((LL_FAIL+1)); fi
    done < "$LLROOT/wanted"
    mv "$LLROOT/details.new" "$LLROOT/details"
    result=waiting
    [ -z "$LL_PACKAGES" ] || result=no_matching_threads
    [ "$LL_OK" = 0 ] || result=verified
    if [ "$LL_FAIL" != 0 ]; then if [ "$LL_OK" = 0 ]; then result=error; else result=partial; fi; fi
    ll_state "$result"
    if [ "$LL_OK" -gt 0 ]; then
        { cat "$LLROOT/status"; cat "$LLROOT/details"; } > "$LLROOT/proof.new"
        mv "$LLROOT/proof.new" "$LLROOT/proof"
    fi
    [ "$LL_FAIL" = 0 ]
}
ll_pause() {
    ll_init || return 1
    touch "$LLROOT/pause"
    ll_lock || { echo error=scheduler_busy_try_again; return 1; }
    if ! ll_restore_all; then ll_unlock; echo error=scheduler_restore_failed; return 1; fi
    LL_OK=0; LL_FAIL=0; ll_read_config; ll_state suspended
    : > "$LLROOT/details"
    ll_unlock
}
ll_resume() { rm -f "$LLROOT/pause"; }
ll_alive() {
    local p
    p=$(cat "$LLROOT/daemon.pid" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$p" 2>/dev/null || return 1
    tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/ha.sh rt-daemon" >/dev/null
}
ll_ensure_daemon() {
    ll_init || return 1
    ll_alive && return 0
    HA_BUSYBOX=0 setsid /system/bin/sh "$MODDIR/bin/ha.sh" rt-daemon </dev/null > "$LLROOT/daemon.log" 2>&1 &
    local n=0
    while [ "$n" -lt 5 ]; do sleep 1; ll_alive && return 0; n=$((n+1)); done
    echo error=scheduler_daemon_not_running; return 1
}
ll_daemon() {
    ll_init || return 1
    ll_lock || return 1
    if ll_alive; then ll_unlock; return 0; fi
    echo $$ > "$LLROOT/daemon.pid"
    ll_unlock
    trap 'if ll_lock; then ll_restore_all; ll_unlock; fi; rm -f "$LLROOT/daemon.pid"' EXIT
    trap 'exit 0' INT TERM HUP
    while [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]; do
        date +%s > "$LLROOT/heartbeat"
        if ll_lock; then ll_tick_locked; ll_unlock; fi
        sleep 5
    done
}
ll_save() {
    ll_valid "$@" || { echo error=invalid_lowlat_parameters; return 1; }
    [ "$(cat "$STATE/applied")" = native ] || { echo error=select_native_first; return 1; }
    ll_init || return 1
    [ "$1" = 0 ] || ll_ensure_daemon || return 1
    ll_lock || { echo error=scheduler_busy_try_again; return 1; }


    {
        echo "enabled=$1"; echo "hal_priority=$2"
        echo "audio_priority=$3"; echo "app_priority=$4"
        echo "revision=$(date +%s)-$$"
    } > "$MODDIR/lowlat.conf.new"
    if ! mv "$MODDIR/lowlat.conf.new" "$MODDIR/lowlat.conf"; then ll_unlock; return 1; fi
    ll_resume
    ll_tick_locked
    local rc=$?
    ll_unlock
    echo saved=1
    cat "$LLROOT/status"
    echo '设置已保存；仅标为 verified 的线程已通过内核状态回读。等待状态请启动游戏并播放声音。'
    return "$rc"
}
ll_status() {
    ll_read_config || return 1
    printf 'enabled=%s\nhal_priority=%s\naudio_priority=%s\napp_priority=%s\nrevision=%s\n' "$LL_ENABLED" "$LL_HAL" "$LL_AUDIO" "$LL_APP" "$LL_REV"
    echo "ll_daemon=$(ll_alive && echo running || echo offline)"
    local beat now
    beat=$(cat "$LLROOT/heartbeat" 2>/dev/null); now=$(date +%s)
    case "$beat" in ''|*[!0-9]*) echo ll_age=unknown ;; *) echo "ll_age=$((now-beat))" ;; esac
    [ ! -f "$LLROOT/status" ] || cat "$LLROOT/status"
    echo current_details_begin
    [ ! -f "$LLROOT/details" ] || cat "$LLROOT/details"
    echo current_details_end
    echo proof_begin
    [ ! -f "$LLROOT/proof" ] || cat "$LLROOT/proof"
    echo proof_end
}
