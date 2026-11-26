#!/bin/sh
# Active-client parser and real ll_targets path host-side regression tests.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/../webui/bin
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_clients_test)
rm -rf "$T"; mkdir -p "$T/mod/bin" "$T/mod/state/lowlat" "$T/proc/2345/task/2345" "$T/stub"
trap 'rm -rf "$T"' EXIT
cp "$BIN/runtime.sh" "$BIN/lowlat.sh" "$BIN/config.sh" "$BIN/active_clients.sh" "$T/mod/bin/"
MODDIR=$T/mod STATE=$T/mod/state BOOT_ID=test LL_PROC_ROOT=$T/proc
export MODDIR STATE BOOT_ID LL_PROC_ROOT
. "$T/mod/bin/runtime.sh"
. "$T/mod/bin/lowlat.sh"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (expected %s, actual %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (missing %s)\n' "$1" "$3" ;; esac; }

cat > "$T/flinger" <<'EOF'
Output thread 0x12, name AudioOut_Primary
  2 Tracks of which 1 are active
    Type Id Active Client Session
    1 F0 yes 2345/  10123 44
    2 F0 no 9999/10124 45
Mmap thread 0x15, type 3 (MMAP_PLAYBACK)
  1 Tracks
    2345 77 1000 1000 1000 1000 1000 1000 1000
Mmap thread 0x18, type 4 (MMAP_CAPTURE)
  1 Tracks
    8888 77 1000 1000 1000 1000 1000 1000 1000
Local log:
  misleading history 0x99
  1 Tracks of which 1 are active
    1 F0 yes 7777/10123 44
EOF
ck 'ordinary active client parsed' "$(ll_active_clients < "$T/flinger")" '2345'
ck 'duplicate ordinary/MMAP PID removed' "$(ll_active_clients < "$T/flinger" | wc -l | tr -d ' ')" '1'

# Set up process identity and an AudioMmapOut thread, then run the actual target collector.
mkdir -p "$T/proc/2345/task/2345"
printf 'Uid:\t10123\t10123\t10123\t10123\n' > "$T/proc/2345/status"
printf 'com.example.game\0' > "$T/proc/2345/cmdline"
printf 'AudioTrack\n' > "$T/proc/2345/task/2345/comm"
mkdir -p "$T/proc/1000/task/1001"
printf 'AudioMmapOut\n' > "$T/proc/1000/task/1001/comm"
cat > "$T/stub/dumpsys" <<EOF
#!/bin/sh
case "\$*" in
  *media.audio_flinger*) cat "$T/flinger" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/stub/pidof" <<'EOF'
#!/bin/sh
case "$1" in audioserver) echo 1000 ;; *) exit 1 ;; esac
EOF
cat > "$T/stub/aaudio" <<EOF
#!/bin/sh
exit 1
EOF
cat > "$T/stub/audiohalservice.qti" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/stub/"*
PATH=$T/stub:$PATH
export PATH
LL_WHITE=com.example.game LL_APP=15 LL_AUDIO=16 LL_HAL=20
ll_targets
ck 'll_targets succeeds with active client' "$?" '0'
ckc 'active whitelisted app becomes a target' "$(cat "$LLROOT/wanted")" '2345 2345 app 15'
ckc 'AudioMmapOut becomes an audio target' "$(cat "$LLROOT/wanted")" '1000 1001 audio 16'
ckc 'package survives whitelist filtering' "$LL_PACKAGES" 'com.example.game'

# An undefined-function regression used to silently skip all valid clients.
# A successful target above proves package validation is defined and reachable.

calls=$T/dumpsys.calls
cat > "$T/stub/dumpsys" <<EOF
#!/bin/sh
echo call >> "$calls"
exit 1
EOF
LL_WHITE=
ll_targets
ck 'empty whitelist succeeds' "$?" '0'
ck 'empty whitelist avoids dumpsys' "$(test -e "$calls" && echo called || echo skipped)" 'skipped'

# Test the live thread matching branch directly with a tiny fake proc tree.
ll_add_threads 1000 audio 16 > "$T/thread.targets"
ckc 'AudioMmapOut thread matched' "$(cat "$T/thread.targets")" '1000 1001 audio 16'

printf '  Passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
