#!/system/bin/sh
MODDIR=${0%/*}
# Late-start only. Never block post-fs-data or modify persistent properties.
N=0
while [ "$(getprop sys.boot_completed)" != 1 ]; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && exit 0
  N=$((N + 1))
  [ "$N" -lt 180 ] || exit 0
  sleep 1
done
[ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && exit 0
sleep 5
# boot starts the scheduler only after validating the configuration.
/system/bin/sh "$MODDIR/bin/ha.sh" boot > "$MODDIR/last_boot.log" 2>&1 || exit 1
