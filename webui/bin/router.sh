#!/system/bin/sh
# Two mutually exclusive routing lists. File formats and the CLI are stable;
# Zygisk falls back to the generation-tagged property banks when files are unavailable.
MODDIR=${MODDIR:-${HA_MOD_DIR:-/data/adb/modules/hyperaudio}}
STATE=$MODDIR/state
BIN=${0%/*}
. "$BIN/config.sh" || exit 1
TXN=$STATE/config-txn
PERAPP=$MODDIR/perapp.conf
CONF=$MODDIR/lowlat.conf

ok() { printf 'ok=1\n'; }
bad() { printf 'error=%s\n' "$1"; }

perapp_apps() {
    [ -f "$PERAPP" ] || return 0
    sed -n 's/^[[:space:]]*app[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.][A-Za-z0-9_.]*\)[[:space:]]*$/\1/p' "$PERAPP"
}
conf_val() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -1
}
conf_num() {
    local v
    v=$(conf_val "$1")
    case "$v" in ''|*[!0-9]*|0*) v=$2 ;; esac
    if [ "${#v}" -gt 2 ]; then v=$2; fi
    printf '%s' "$v"
}
csv_lines() {
    case "$1" in ''|-) return 0 ;; esac
    printf '%s\n' "$1" | tr ',' '\n'
}
lines_csv() { paste -sd, -; }
contains() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
remove_pkg() { csv_lines "$1" | grep -Fxv "$2" | lines_csv; }
add_pkg() { if [ -n "$1" ]; then printf '%s,%s' "$1" "$2"; else printf '%s' "$2"; fi; }

load_lists() {
    # Reject directories and other non-regular paths rather than mv-ing into them.
    for f in "$PERAPP" "$CONF"; do
        [ ! -e "$f" ] || [ -f "$f" ] || return 1
    done
    SOUND=$(perapp_apps | lines_csv)
    WHITE=$(conf_val whitelist)
    [ "$WHITE" != - ] || WHITE=
}

validate_csv() {
    local csv=$1 pkg
    case "$csv" in '' ) return 0 ;; ,*|*,|*,,*) return 1 ;; esac
    while [ -n "$csv" ]; do
        pkg=${csv%%,*}
        config_pkg_ok "$pkg" || return 1
        case "$csv" in *,*) csv=${csv#*,} ;; *) csv= ;; esac
    done
}

# The CSV stream is ASCII. Split across package boundaries, not inside a C string
# at the reader: every non-empty chunk is concatenated before CSV membership tests.
# Stage every slot and verify every read-back before exposing the new bank.
prop_stage() {
    local prefix=$1 data=$2 active gen bank slot i=0 chunk pointer
    active=$(getprop "ha.$prefix.active") || return 1
    gen=$(getprop "ha.$prefix.gen") || return 1
    case "$active" in *.0) bank=1 ;; *.1) bank=0 ;; *) bank=0 ;; esac
    pointer=${active%.*}
    case "$pointer" in ''|0*|*[!0-9]*) pointer=0 ;; esac
    case "$gen" in ''|0*|*[!0-9]*) gen=0 ;; esac
    [ "${#gen}" -le 9 ] && [ "${#pointer}" -le 9 ] || return 1
    [ "$gen" -ge "$pointer" ] || gen=$pointer
    [ "$gen" -lt 999999999 ] || return 1
    gen=$((gen+1))
    printf '%s\n' "$active" > "$TXN/$prefix.active" || return 1
    printf '%s\n' "$(getprop "ha.$prefix.gen")" > "$TXN/$prefix.gen" || return 1
    printf '%s\n' "$gen.$bank" > "$TXN/$prefix.next" || return 1
    # One awk invocation writes exactly 32 lines (a literal '-' for every unused slot).
    printf '%s\n' "$data" | LC_ALL=C awk '{for(i=0;i<32;i++){s=substr($0,i*80+1,80); print (s=="" ? "-" : s)}}' > "$TXN/$prefix.chunks" || return 1
    while IFS= read -r chunk; do
        slot=ha.$prefix.$bank.$i
        local observed
        observed=$(getprop "$slot") || return 1
        if [ "$observed" != "$chunk" ]; then
            setprop "$slot" "$chunk" || return 1
            [ "$(getprop "$slot")" = "$chunk" ] || return 1
        fi
        i=$((i+1))
    done < "$TXN/$prefix.chunks"
    [ "$i" = 32 ] || return 1
    return 0
}
prop_commit() {
    local prefix=$1 active gen
    active=$(cat "$TXN/$prefix.next") || return 1
    gen=${active%.*}
    setprop "ha.$prefix.gen" "$gen" || return 1
    [ "$(getprop "ha.$prefix.gen")" = "$gen" ] || return 1
    setprop "ha.$prefix.active" "$active" || return 1
    [ "$(getprop "ha.$prefix.active")" = "$active" ]
}

write_perapp_stage() {
    printf 'enabled=1\n' || return 1
    if [ -n "$SOUND" ]; then csv_lines "$SOUND" | sed 's/^/app=/'; fi
}
file_stage() {
    local name=$1 path=$MODDIR/$1
    if [ -f "$path" ]; then
        cp -p "$path" "$TXN/$name.old" || return 1
    else
        : > "$TXN/$name.absent" || return 1
    fi
    case "$name" in
      perapp.conf) write_perapp_stage > "$TXN/$name.new" || return 1 ;;
      lowlat.conf) config_lowlat_write "$(conf_num hal_priority 20)" "$(conf_num audio_priority 16)" \
          "$(conf_num app_priority 15)" "$WHITE" > "$TXN/$name.new" || return 1 ;;
    esac
    chmod 0644 "$TXN/$name.new"
}
file_commit() { mv -fT "$TXN/$1.new" "$MODDIR/$1"; }

publish_state() { printf '%s\n' "$1" > "$STATE/config-publish"; }
transaction_fail() {
    local reason=$1
    if ! config_recover; then reason=recovery_failed; fi
    publish_state "$reason"
    bad "$reason"
    return 1
}
transaction() {
    local f prefix source dest
    # Capacity and syntax are checked for both candidate lists before any change.
    if [ "${#SOUND}" -gt 2560 ] || [ "${#WHITE}" -gt 2560 ]; then
        publish_state property_capacity_exceeded
        bad property_capacity_exceeded; return 1
    fi
    if ! validate_csv "$SOUND" || ! validate_csv "$WHITE"; then
        publish_state invalid_config
        bad invalid_config; return 1
    fi
    (umask 077; mkdir "$TXN") || { bad write_failed; return 1; }
    for f in "$@"; do file_stage "$f" || { transaction_fail write_failed; return 1; }; done
    if ! prop_stage perapp.app "$SOUND" >/dev/null 2>&1 || ! prop_stage mmap_gate "$WHITE" >/dev/null 2>&1; then
        transaction_fail publish_failed; return 1
    fi
    # A crash after .pending is written causes rollback on next lock acquisition.
    # Commit source-list deletion first, so no package is in both published lists.
    : > "$TXN/undo-files"
    for f in "$@"; do printf '%s\n' "$f"; done | awk '{line[NR]=$0} END {for(i=NR;i>0;i--)print line[i]}' > "$TXN/undo-files" || { transaction_fail write_failed; return 1; }
    case "${1:-}" in lowlat.conf) source=mmap_gate; dest=perapp.app ;; *) source=perapp.app; dest=mmap_gate ;; esac
    printf '%s\n' "$dest" "$source" > "$TXN/undo-props" && : > "$TXN/pending" || { transaction_fail write_failed; return 1; }
    for f in "$@"; do file_commit "$f" || { transaction_fail write_failed; return 1; }; done
    set -- "$source" "$dest"
    for prefix in "$@"; do
        prop_commit "$prefix" >/dev/null 2>&1 || { transaction_fail publish_failed; return 1; }
    done
    rm -f "$TXN/pending" || { transaction_fail write_failed; return 1; }
    rm -rf "$TXN"
    publish_state ok
}

refresh_description() {
    [ ! -f "$MODDIR/bin/runtime.sh" ] ||
        ( . "$MODDIR/bin/runtime.sh"; update_description ) >/dev/null 2>&1 || :
}
cmd_status() {
    local ns nw pay=0 comp=0 pub
    ns=$(csv_lines "$SOUND" | wc -l | tr -d ' ')
    nw=$(csv_lines "$WHITE" | wc -l | tr -d ' ')
    [ ! -s "$MODDIR/zygisk/arm64-v8a.so" ] || pay=1
    ps -A 2>/dev/null | grep -Eq 'zn-zygisk-companion64 (hyperaudio|dolbyrouter)' && comp=1
    pub=$(cat "$STATE/config-publish" 2>/dev/null) || pub=unknown
    printf 'perapp_count=%s\nperapp_apps=%s\nperapp_payload=%s\nperapp_companion=%s\nwl_count=%s\nwl_apps=%s\nconfig_publish=%s\n' \
        "$ns" "$SOUND" "$pay" "$comp" "$nw" "$WHITE" "$pub"
    ok
}
cmd_edit() {
    local action=$1 pkg=$2 moved= old_sound=$SOUND old_white=$WHITE
    config_pkg_ok "$pkg" || { bad bad_package; return 0; }
    case "$action" in
      perapp-add)
        if contains "$WHITE" "$pkg"; then WHITE=$(remove_pkg "$WHITE" "$pkg"); moved=lowlat; fi
        contains "$SOUND" "$pkg" || SOUND=$(add_pkg "$SOUND" "$pkg") ;;
      wl-add)
        if contains "$SOUND" "$pkg"; then SOUND=$(remove_pkg "$SOUND" "$pkg"); moved=sound; fi
        contains "$WHITE" "$pkg" || WHITE=$(add_pkg "$WHITE" "$pkg") ;;
      perapp-del) SOUND=$(remove_pkg "$SOUND" "$pkg") ;;
      wl-del) WHITE=$(remove_pkg "$WHITE" "$pkg") ;;
    esac
    set --
    if [ "$SOUND" != "$old_sound" ]; then set -- perapp.conf; fi
    if [ "$WHITE" != "$old_white" ]; then
        case "$moved" in lowlat) set -- lowlat.conf "$@" ;; *) set -- "$@" lowlat.conf ;; esac
    fi
    # Even a no-op can repair a prior failed/unknown property publication.
    if [ "$#" -ne 0 ] || [ "$(cat "$STATE/config-publish" 2>/dev/null)" != ok ]; then
        transaction "$@" || return 0
        refresh_description
    fi
    ok
    [ -z "$moved" ] || printf 'moved_from=%s\n' "$moved"
}
clear_properties() {
    local prefix bank i failed=0
    for prefix in perapp.app mmap_gate; do
        # An invalidated new pointer is authoritative (never fall back to stale data).
        setprop "ha.$prefix.active" - || failed=1
        for bank in 0 1; do
            i=0
            while [ "$i" -lt 32 ]; do
                setprop "ha.$prefix.$bank.$i" - || failed=1
                i=$((i+1))
            done
        done
        i=0
        while [ "$i" -lt 8 ]; do setprop "ha.$prefix.$i" - || failed=1; i=$((i+1)); done
        setprop "ha.$prefix.gen" - || failed=1
    done
    [ "$failed" = 0 ] || { bad publish_failed; return 1; }
}

case "${1:-}" in
    router-status|perapp-add|perapp-del|wl-add|wl-del|publish-only|clear-properties) ;;
    *) bad bad_action; exit 0 ;;
esac
if ! config_lock; then bad scheduler_busy_try_again; exit 1; fi
trap 'config_unlock' EXIT
trap 'exit 1' HUP INT TERM
if [ "$1" = clear-properties ]; then clear_properties; exit $?; fi
if ! config_recover; then publish_state recovery_failed; bad recovery_failed; exit 1; fi
if ! load_lists; then bad write_failed; exit 1; fi
case "$1" in
    router-status) cmd_status ;;
    perapp-add|perapp-del|wl-add|wl-del) cmd_edit "$1" "${2:-}" ;;
    publish-only) transaction && refresh_description ;;
esac
