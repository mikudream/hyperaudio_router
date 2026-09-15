#!/system/bin/sh
# ============================================================
# 检测"调音来源"
# ============================================================
# 扫描 /data/adb/modules 下携带音频调音载荷的模块，并用 md5 与 /odm 上
# 生效的文件比对，判断哪一份真正生效。
#
# 输出（单行）：
#   module=<目录名> name=<显示名> version=<版本> verified=1|0
#   未检测到： module=none name=未检测到调音模块 version= verified=0
# ============================================================

MODROOT=/data/adb/modules

# 载荷相对路径|对应的 /odm 生效路径
PAYLOADS="Link/odm/etc/dolby/dax-default.xml|/odm/etc/dolby/dax-default.xml
odm/etc/dolby/dax-default.xml|/odm/etc/dolby/dax-default.xml
Link/odm/etc/audio/sku_canoe/mixer_paths_canoe_mtp.xml|/odm/etc/audio/sku_canoe/mixer_paths_canoe_mtp.xml
odm/etc/audio/sku_canoe/mixer_paths_canoe_mtp.xml|/odm/etc/audio/sku_canoe/mixer_paths_canoe_mtp.xml
Link/odm/etc/acdbdata/Mi_acdb_cal.acdb|/odm/etc/acdbdata/Mi_acdb_cal.acdb
odm/etc/acdbdata/Mi_acdb_cal.acdb|/odm/etc/acdbdata/Mi_acdb_cal.acdb"

FOUND=""
VERIFIED="0"

for d in "$MODROOT"/*/; do
  m=$(basename "$d")
  [ "$m" = "hyperaudio" ] && continue
  [ -f "$d/module.prop" ] || continue

  HIT=0
  HITV=0
  # 用 printf + while read 逐行解析（在子 shell 中，故用标记文件传递结果）
  RES=$(printf '%s\n' "$PAYLOADS" | while IFS='|' read -r rel eff; do
    [ -n "$rel" ] || continue
    f="$d$rel"
    [ -f "$f" ] || continue
    echo HIT
    if [ -f "$eff" ]; then
      a=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
      b=$(md5sum "$eff" 2>/dev/null | awk '{print $1}')
      [ -n "$a" ] && [ "$a" = "$b" ] && echo HITV
    fi
  done)
  case "$RES" in *HIT*) HIT=1 ;; esac
  case "$RES" in *HITV*) HITV=1 ;; esac

  if [ "$HIT" = "1" ]; then
    FOUND="$m"
    VERIFIED="$HITV"
    break
  fi
done

if [ -n "$FOUND" ]; then
  NAME=$(grep -m1 '^name=' "$MODROOT/$FOUND/module.prop" 2>/dev/null | cut -d= -f2-)
  VER=$(grep -m1 '^version=' "$MODROOT/$FOUND/module.prop" 2>/dev/null | cut -d= -f2-)
  echo "module=$FOUND name=${NAME:-$FOUND} version=${VER:-未知} verified=$VERIFIED"
else
  echo "module=none name=未检测到调音模块 version= verified=0"
fi
