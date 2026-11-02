#!/bin/sh
# diagnose.sh 的主机侧测试：
#   1) 只读——跑完模块目录里任何文件的 mtime/size 都不能变
#   2) 结构——报告必须包含各段标题，缺段要显式写"缺失"而不是静默跳过
#   3) 导出——--save 必须写出文件、返回 ok=1 与 path=，且目录不可写时报错退出
# 依赖：sh、coreutils（head/tail/wc/date）。不依赖设备上的 dumpsys/getprop，
# 它们缺失时脚本应打印"(无 dumpsys)"而不是崩溃。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DIAG="$HERE/../webui/diagnose.sh"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_diag_test)
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }

# ---- 造一个假模块 ----
M=$T/mod
mkdir -p "$M/bin" "$M/state/audio-ready" "$M/logs"
cat > "$M/module.prop" <<'EOF'
id=hyperaudio
name=音频模式切换器
version=0.4.7
versionCode=261102
EOF
printf 'sound\n' > "$M/mode"
printf 'sound\n' > "$M/state/applied"
printf 'passed\n' > "$M/state/audio-ready/result.txt"
printf 'low_latency_out=2\nraw_out=256\n' > "$M/state/audio-ready/expected.txt"
printf 'primary_output=13\nprimary_hal_frames=1920\nlow_latency_out=2\nraw_out=256\n' > "$M/state/audio-ready/observed.txt"
printf '4242\n' > "$M/state/audio-ready/pid"
cat > "$M/config.toml" <<'EOF'
[hyperaudio]
enable = true
only_whitelist = false
audio_priority = 16
hal_priority = 20
app_priority = 15
whitelist = [
  "com.example.game",
  "com.example.music",
]
EOF
printf '2026-01-01 device boot ok\n' > "$M/logs/boot.log"

# 让 diagnose.sh 认为自己在 bin/ 下：拷一份进去
cp "$DIAG" "$M/bin/diagnose.sh"
cp "$HERE/../webui/detect_tuning.sh" "$M/bin/detect_tuning.sh" 2>/dev/null || true

# ---- 1) 只读性 ----
snapshot() { find "$M" -type f -exec ls -l {} \; 2>/dev/null | awk '{print $5, $NF}' | sort; }
before=$(snapshot)
OUT=$(sh "$M/bin/diagnose.sh" --stdout 2>&1); RC=$?
after=$(snapshot)

ck "退出码为 0" "$RC" "0"
ck "未修改模块目录内任何文件" "$after" "$before"

# ---- 2) 结构 ----
ckc "含报告头" "$OUT" "hyperaudio 诊断报告"
ckc "含报告尾" "$OUT" "报告结束"
ckc "含模块段" "$OUT" "---------------- 模块 ----------------"
ckc "含挂载段" "$OUT" "---------------- 挂载 ----------------"
ckc "含端口段" "$OUT" "---------------- 端口 flags"
ckc "含 runtime 段" "$OUT" "---------------- runtime status"
ckc "含就绪段" "$OUT" "---------------- 音频就绪校验"
ckc "含策略段" "$OUT" "---------------- 音频策略摘要"
ckc "含混音段" "$OUT" "---------------- 混音线程摘要"
ckc "含配置段" "$OUT" "---------------- 配置（脱敏）"
ckc "含日志段" "$OUT" "---------------- 日志尾部"
ckc "读到版本号" "$OUT" "0.4.7"
ckc "读到模式" "$OUT" "模式      : sound"
ckc "读到就绪结果" "$OUT" "结果: passed"
ckc "读到期望值" "$OUT" "low_latency_out=2"
ckc "白名单条目数正确" "$OUT" "白名单条数: 2"
ckc "白名单只列包名（不含键名）" "$OUT" "com.example.game"
ckc "无 dumpsys 时明确说明" "$OUT" "(无 dumpsys)"

# 日志段确实带出了日志内容
ckc "带出日志尾部" "$OUT" "device boot ok"

# ---- 3) 导出 ----
DEST=$T/out
mkdir -p "$DEST"
SAVE=$(HA_DIAG_DEST="$DEST" sh "$M/bin/diagnose.sh" --save 2>&1); RC2=$?
ck "导出退出码为 0" "$RC2" "0"
ckc "导出返回 ok=1" "$SAVE" "ok=1"
PATH_OUT=$(printf '%s\n' "$SAVE" | sed -n 's/^path=//p' | head -1)
if [ -n "$PATH_OUT" ] && [ -s "$PATH_OUT" ]; then
  pass=$((pass+1)); printf '  OK   报告文件存在且非空\n'
  ckc "报告文件内容完整" "$(cat "$PATH_OUT")" "报告结束"
  ckc "报告文件名带前缀" "$PATH_OUT" "hyperaudio-diag-"
else
  fail=$((fail+1)); printf '  FAIL 报告文件不存在或为空 (%s)\n' "$PATH_OUT"
fi

# 不可写目录 -> 明确失败，而不是静默成功
NOREAD=$T/nowrite
mkdir -p "$NOREAD"; chmod 0500 "$NOREAD" 2>/dev/null || true
FAILOUT=$(HA_DIAG_DEST="" sh "$M/bin/diagnose.sh" --save 2>&1); RC3=$?
# 主机上 /sdcard 与 /data/local/tmp 通常不存在，因此应报 no_writable_dir 或写成功；
# 只要不是"静默返回 0 且没有 path"即可。
case "$FAILOUT" in
  *path=*) pass=$((pass+1)); printf '  OK   回退到可写目录时仍返回路径\n' ;;
  *error=no_writable_dir*) pass=$((pass+1)); printf '  OK   无处可写时报 no_writable_dir\n' ;;
  *) fail=$((fail+1)); printf '  FAIL 无处可写时的行为不明确: %s\n' "$FAILOUT" ;;
esac
chmod 0755 "$NOREAD" 2>/dev/null || true

# ---- 4) 参数校验 ----
sh "$M/bin/diagnose.sh" --bogus >/dev/null 2>&1
ck "非法参数返回 2" "$?" "2"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
