#!/system/bin/sh
MODPATH=${0%/*}

# MODPATH=/data/adb/modules/hyperaudio

# 本模块不含 odm 调音载荷，此段仅作兜底：
# 若将来手动放入 $MODPATH/odm，会在开机时逐个 bind mount 覆盖到 /odm；
# 目录不存在则直接退出，避免 find 报错，也不触碰 /odm。
#
# 注意（原实现的两个问题，已修）：
#   1) 原先写的是 `/bin/mount <src> <dst>`，**缺 --bind**。对普通文件执行不带
#      -t/--bind 的 mount，内核会返回 ENODEV，所以这段兜底从未真正生效。
#   2) 原先用 `$(find ... -printf "%P ")` 未加引号做词分裂：文件名含空格即断词；
#      且 -printf 是 GNU 扩展，toybox 未必支持。改用 POSIX 的 find + while read。
[ -d "$MODPATH/odm" ] || exit 0

find "$MODPATH/odm" -type f | while IFS= read -r f; do
  rel=${f#$MODPATH/odm/}
  dst=/odm/$rel
  [ -f "$dst" ] || continue
  mount --bind "$f" "$dst" 2>/dev/null || continue
  restorecon "$dst" 2>/dev/null
done
