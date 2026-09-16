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
  # 去掉尾斜杠：否则拼出的搜索路径含 "//"，而 find 会把路径归一化，
  # 于是 ${f#$d/} 剥离失败、rel 变成绝对路径、生效路径又拼回模块自身，
  # md5 成了自比较 —— 结果是【任何】模块都被判成"已生效"（曾实测复现）。
  d="${1%/}"
  DIRS=""
  for p in "$d/Link/odm/etc" "$d/Link/vendor/etc" "$d/Link/system/etc" \
           "$d/odm/etc" "$d/vendor/etc" "$d/system/etc" "$d/system/vendor/etc" \
           "$d/system_ext/etc"; do
    [ -d "$p" ] && DIRS="$DIRS $p"
  done
  [ -n "$DIRS" ] || { echo ""; return 0; }

  # 过滤交给 find 自己做（-path 定位目录、-name 匹配文件名），
  # 避免对每个文件都起一个 echo|grep 进程（每进程约 70ms）。
  CANDS=$(find $DIRS -type f \
      \( -path '*/dolby/*' -o -path '*/audio/*' -o -path '*/acdbdata/*' \
         -name 'dax-*' -o -name 'dax_default*' -o -name 'mixer_paths*' \
         -o -name 'acdb*' -o -name 'audio_effects_config.*' \
         -o -name 'audio_module_config_*' -o -name 'resourcemanager*' \) 2>/dev/null)

  # 显式排除：这些属于路由/音量策略，不是调音载荷
  CANDS=$(echo "$CANDS" | grep -vE 'audio_policy_configuration|audio_policy_engine|volume|audio_lowpower_app_list')

  for f in $CANDS; do
    rel="${f#$d/}"
    # 双保险：rel 必须是相对路径，否则说明处理有误，跳过以免自比较
    case "$rel" in /*|"") continue ;; esac
    echo "$rel" | grep -Eq "$PAYLOAD_PAT" || continue

    eff="/${rel#Link/}"
    # eff 必须落在模块之外，否则又是自比较
    case "$eff" in "$d"/*) echo HIT; return 0 ;; esac
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
