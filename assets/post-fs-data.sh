MODPATH=${0%/*}

# MODPATH=/data/adb/modules/hyperaudio

# 本模块不含 odm 调音载荷，此段仅作兜底：
# 若将来手动放入 $MODPATH/odm，会在开机时逐个 bind mount 覆盖到 /odm；
# 目录不存在则直接退出，避免 /bin/find 报错，也不触碰 /odm。
[ -d "$MODPATH/odm" ] || exit 0

for i in `/bin/find $MODPATH/odm -type f -printf "%P "`; do
    /bin/mount /$MODPATH/odm/$i /odm/$i
    restorecon /odm/$i
done
