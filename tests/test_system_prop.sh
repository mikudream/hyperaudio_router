#!/bin/sh
# system.prop 的主机侧守护测试。
# 背景：本模块的低延迟能力分两类——策略/缓冲类（真实生效）与 MMAP/ULL 解锁类
# （在本机实测不改变 AAudio 是否走 MMAP）。这两类混在一起时，很容易在
# UI 上做出"已开启 MMAP"这种不实承诺，或者不小心把关键属性删掉。
#
# 所以这里锁住四条：
#   1) 没有任何重复键（重复会让"到底哪个生效"无法判断）
#   2) 键名格式合法、没有值里带空格导致的解析歧义
#   3) 关键属性存在（删了会影响低延迟/编解码）
#   4) 文件里必须有说明"MMAP 属性不改变行为"的注释（防止后人又去改它求效果）
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PROP="$HERE/../assets/system.prop"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含: %s)\n' "$1" "$3" ;; esac; }

ck "文件存在" "$([ -f "$PROP" ] && echo yes || echo no)" "yes"

# --- 1) 重复键 ---
dups=$(grep -v '^\s*#' "$PROP" 2>/dev/null | grep -v '^\s*$' | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.]*\)[[:space:]]*=.*/\1/p' | sort | uniq -d)
ck "无重复键" "[$dups]" "[]"

# --- 2) 键名/格式 ---
badkey=$(grep -v '^\s*#' "$PROP" 2>/dev/null | grep -v '^\s*$' | grep -vcE '^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=')
ck "每行都是 key=value" "$badkey" "0"
empties=$(grep -v '^\s*#' "$PROP" 2>/dev/null | grep -cE '^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=[[:space:]]*$')
ck "没有空值条目" "$empties" "0"

# --- 3) 关键属性 ---
for k in \
  vendor.audio_hal.period_size \
  vendor.audio.adm.buffering.ms \
  af.fast_track_multiplier \
  persist.vendor.audio.aaudio.support \
  aaudio.mmap_policy \
  audio.offload.disable ; do
  ckc "存在 $k" "$(cat "$PROP")" "$k="
done

# --- 4) 说明性注释（防止后人又用改属性去求 MMAP 效果）---
txt=$(cat "$PROP")
ckc "注明了 MMAP 属性不改变行为" "$txt" "不改变"
ckc "注明了真正的 MMAP 来源是自带的库" "$txt" "libaaudio_internal.so"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
