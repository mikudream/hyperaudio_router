#!/system/bin/sh
# ============================================================
# 检测"调音来源"
# ============================================================
# 判定策略（放宽命中范围）：
#   对 /data/adb/modules 下每个模块，扫描其内部所有文件，凡"路径 + 文件名"
#   符合调音载荷特征者即计入命中，再与生效路径做 md5 比对判断是否真正生效。
#
#   路径特征：位于 dolby / audio / acdbdata 目录下，或直接位于 */etc/ 下
#   文件名特征：dax-*  dax_default*  mixer_paths*  acdb*
#               audio_effects_config.*  audio_module_config_*  resourcemanager*
#
#   明确排除（属于路由/音量策略，不是调音）：audio_policy_configuration.xml、
#   audio_policy_engine_*、*volume*、audio_lowpower_app_list.xml 等
#
#   生效路径推导：模块内 <X> 对应设备上 /<X>；模块可能用 Link/ 前缀
#   （自己 bind mount）或直接 odm/、vendor/、system/vendor/ 布局，两种都覆盖。
#
# 输出（单行）：
#   命中一个： module=<目录名> name=<显示名> version=<版本> verified=0|1 count=1
#   命中多个： module=<生效的那个> name=<N 个调音模块> version= verified=0|1 count=N
#   未命中：   module=none name=未检测到调音模块 version= verified=0 count=0
# ============================================================

MODROOT=/data/adb/modules

# 调音载荷特征：命中即视为携带调音内容
PAYLOAD_PAT='(dolby|audio|acdbdata)/.*(dax-|dax_default|mixer_paths|acdb|audio_effects_config|audio_module_config|resourcemanager)|etc/(dax-|dax_default|mixer_paths|acdb|audio_effects_config|audio_module_config|resourcemanager)'

# 探测单个模块：命中则输出 HIT（仅存在）/ HITV（且已生效），并提前退出
probe_module() {
  d="$1"
  for f in $(find "$d" -type f 2>/dev/null); do
    rel="${f#$d/}"
    echo "$rel" | grep -Eq "$PAYLOAD_PAT" || continue

    eff="/${rel#Link/}"
    [ -f "$eff" ] || continue

    a=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
    b=$(md5sum "$eff" 2>/dev/null | awk '{print $1}')
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
      echo HITV
      return 0
    fi
    echo HIT
    return 0
  done
  echo ""
}

HITS=""
VHIT=""
for d in "$MODROOT"/*/; do
  m=$(basename "$d")
  [ "$m" = "hyperaudio" ] && continue
  [ -f "$d/module.prop" ] || continue
  r=$(probe_module "$d")
  [ -n "$r" ] || continue
  HITS="$HITS $m"
  [ "$r" = "HITV" ] && [ -z "$VHIT" ] && VHIT="$m"
done

CNT=$(echo $HITS | wc -w | tr -d ' ')

if [ -z "$HITS" ]; then
  echo "module=none name=未检测到调音模块 version= verified=0 count=0"
  exit 0
fi

# 生效的模块优先；否则取扫描到的第一个
EFF="${VHIT:-$(echo $HITS | awk '{print $1}')}"
VERIFIED=0
[ -n "$VHIT" ] && VERIFIED=1

if [ "$CNT" = "1" ]; then
  NAME=$(grep -m1 '^name=' "$MODROOT/$EFF/module.prop" 2>/dev/null | cut -d= -f2-)
  VER=$(grep -m1 '^version=' "$MODROOT/$EFF/module.prop" 2>/dev/null | cut -d= -f2-)
  printf 'module=%s name=%s version=%s verified=%s count=1\n' \
    "$EFF" "${NAME:-$EFF}" "${VER:-未知}" "$VERIFIED"
else
  # 多支调音模块：报出全部目录名，便于排查冲突
  printf 'module=%s name=%s version=%s verified=%s count=%s\n' \
    "$EFF" "${CNT}个调音模块:$(echo $HITS | tr ' ' ',')" "" "$VERIFIED" "$CNT"
fi
