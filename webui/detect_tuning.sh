#!/system/bin/sh
# ============================================================
# 检测"调音来源"
# ============================================================
# 输出（单行）：
#   module=<目录名> name=<显示名> version=<版本> verified=0|1 count=N
#   未检测到：module=none name=官方默认调音 version= verified=0 count=0
#
# 判定：模块内文件凡"路径 + 文件名"符合调音载荷特征即计入命中。
#   路径：dolby / audio / acdbdata 目录，或直接位于 */etc/ 下
#   文件名：dax-*  dax_default*  mixer_paths*  acdb*
#           audio_effects_config.*  audio_module_config_*  resourcemanager*
#   排除（属路由/音量策略而非调音）：audio_policy_configuration.xml、
#   audio_policy_engine_*、*volume*、audio_lowpower_app_list.xml
#   生效路径由模块内相对路径推导：<X> ↔ /<X>（剥掉 Link/ 前缀），
#   因此 Link/odm、裸 odm、vendor、system/vendor 布局都能覆盖。
#
# 性能：本设备每次进程启动约 70ms，所以
#   1) 只在可能存放载荷的目录下 find，不做全模块树扫描
#   2) 每个模块一旦命中就立即返回，不再逐项 md5
# ============================================================

MODROOT=/data/adb/modules

PAYLOAD_PAT='(dolby|audio|acdbdata)/.*(dax-|dax_default|mixer_paths|acdb|audio_effects_config|audio_module_config|resourcemanager)|etc/(dax-|dax_default|mixer_paths|acdb|audio_effects_config|audio_module_config|resourcemanager)'

# 探测单个模块：命中输出 HIT（仅存在）/ HITV（且已生效），未命中输出空
probe_module() {
  d="$1"
  DIRS=""
  for p in "$d/Link/odm/etc" "$d/Link/vendor/etc" "$d/odm/etc" "$d/vendor/etc" \
           "$d/system/etc" "$d/system/vendor/etc" "$d/system_ext/etc"; do
    [ -d "$p" ] && DIRS="$DIRS $p"
  done
  [ -n "$DIRS" ] || { echo ""; return 0; }

  # DIRS 需要按空格分词展开
  for f in $(find $DIRS -type f 2>/dev/null); do
    rel="${f#$d/}"
    echo "$rel" | grep -Eq "$PAYLOAD_PAT" || continue

    eff="/${rel#Link/}"
    if [ -f "$eff" ]; then
      a=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
      b=$(md5sum "$eff" 2>/dev/null | awk '{print $1}')
      if [ -n "$a" ] && [ "$a" = "$b" ]; then echo HITV; return 0; fi
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
  # 未检测到第三方调音 → 视为设备官方默认调音
  echo "module=none name=官方默认调音 version= verified=0 count=0"
  exit 0
fi

# 已生效的模块优先；否则取扫描到的第一个
EFF="${VHIT:-$(echo $HITS | awk '{print $1}')}"
VERIFIED=0
[ -n "$VHIT" ] && VERIFIED=1

if [ "$CNT" = "1" ]; then
  NAME=$(grep -m1 '^name=' "$MODROOT/$EFF/module.prop" 2>/dev/null | cut -d= -f2-)
  VER=$(grep -m1 '^version=' "$MODROOT/$EFF/module.prop" 2>/dev/null | cut -d= -f2-)
  printf 'module=%s name=%s version=%s verified=%s count=1\n' \
    "$EFF" "${NAME:-$EFF}" "${VER:-未知}" "$VERIFIED"
else
  # 多支调音模块：列出全部目录名，便于排查挂载覆盖
  printf 'module=%s name=%s version=%s verified=%s count=%s\n' \
    "$EFF" "${CNT}个调音模块:$(echo $HITS | tr ' ' ',')" "" "$VERIFIED" "$CNT"
fi
