#!/bin/sh
# ============================================================
# 音频就绪校验组件测试（主机侧）
# ============================================================
# 覆盖：
#   1) patch_ports.awk 的 report_flags 模式位掩码（与 AOSP audio_output_flags_t 对齐）
#   2) check_audio_ready.awk 对两种 dumpsys 布局的解析
#   3) 不符 / 无法识别 / 主输出缺失 三类结果可区分
#
# 注意：这些是**离线夹具**，只能证明解析逻辑；真实 dumpsys 输出格式
# 必须用真机确认（见 tests/run.sh 的说明）。
# ============================================================
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PATCHER="$HERE/../webui/patch_ports.awk"
CHECKER="$HERE/../webui/check_audio_ready.awk"
T=${TMPDIR:-/tmp}/ha_ready_$$
mkdir -p "$T" || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  OK   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
ck_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

echo "############ 1. report_flags 位掩码 ############"
cat > "$T/base.xml" <<'XML'
<audioPolicyConfiguration>
  <mixPorts>
    <mixPort name="low_latency_out" role="source" flags="FAST|PRIMARY"></mixPort>
    <mixPort name="raw_out" role="source" flags="FAST|RAW"></mixPort>
  </mixPorts>
</audioPolicyConfiguration>
XML

# 摘掉 FAST（本模块 sound 模式的做法）：low 只剩 PRIMARY=2，raw 只剩 RAW=256
awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=0 -v report_flags=1 \
  -f "$PATCHER" "$T/base.xml" > "$T/patched.txt" 2>"$T/e1.txt"
ck_eq "摘 FAST 成功" "$?" "0"
ck_eq "low_latency_out = PRIMARY(2)" "$(sed -n 's/^low_latency_out=//p' "$T/patched.txt")" "2"
ck_eq "raw_out = RAW(256)" "$(sed -n 's/^raw_out=//p' "$T/patched.txt")" "256"

# 不摘任何标志：low=PRIMARY+FAST=6，raw=FAST+RAW=260
awk -v remove_fast_low=0 -v remove_fast_raw=0 -v remove_raw=0 -v report_flags=1 \
  -f "$PATCHER" "$T/base.xml" > "$T/raw.txt" 2>/dev/null
ck_eq "low_latency_out = PRIMARY+FAST(6)" "$(sed -n 's/^low_latency_out=//p' "$T/raw.txt")" "6"
ck_eq "raw_out = FAST+RAW(260)" "$(sed -n 's/^raw_out=//p' "$T/raw.txt")" "260"

# 不带 report_flags 时必须仍然输出 XML，而不是位掩码
awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=0 \
  -f "$PATCHER" "$T/base.xml" > "$T/xml.txt" 2>/dev/null
if grep -q '<mixPorts>' "$T/xml.txt" && grep -q 'flags="PRIMARY"' "$T/xml.txt"; then
  ok "默认模式仍输出改写后的 XML"
else
  bad "默认模式没有输出 XML"
fi
ck_eq "XML 里 raw_out 保留 RAW" "$(grep -c 'name="raw_out" role="source" flags="RAW"' "$T/xml.txt")" "1"

echo ""
echo "############ 2. check_audio_ready.awk：两种 dumpsys 布局 ############"
# 布局 A："; \"primary\"" 与 Handle 同一行
cat > "$T/policy_a.txt" <<'P'
Audio Policy Manager
  Primary Output I/O handle: 15
Outputs:
  1. Handle: 15 ; "primary"
     Output MixPorts:
       1. "low_latency_out"; flags 0x00000002
       2. "raw_out"; flags 0x00000100
P
# 布局 B："; \"primary\"" 单独一行
cat > "$T/policy_b.txt" <<'P'
Audio Policy Manager
  Primary Output I/O handle: 15
Outputs:
  1. Handle: 15
     ; "primary"
     Output MixPorts:
       1. "low_latency_out"; flags 0x00000002
       2. "raw_out"; flags 0x00000100
P
cat > "$T/flinger.txt" <<'F'
Output thread 0x7f: type 0
  I/O handle: 15
  HAL frame count: 960
F

run_check() { # run_check <policy> <expect_low> <expect_raw> ; 输出 rc
  awk -v expected_low="$2" -v expected_raw="$3" \
      -f "$CHECKER" "$1" "$T/flinger.txt" > "$T/obs.txt" 2> "$T/reason.txt"
  echo $?
}

ck_eq "布局A 匹配 (2/256)" "$(run_check "$T/policy_a.txt" 2 256)" "0"
ck_eq "布局B 匹配 (2/256)" "$(run_check "$T/policy_b.txt" 2 256)" "0"
ck_eq "布局A 观测到 primary=15" "$(sed -n 's/^primary_output=//p' "$T/obs.txt")" "15"

ck_eq "不符时失败 (6/260)" "$(run_check "$T/policy_a.txt" 6 260)" "1"
ck_eq "不符原因准确" "$(cat "$T/reason.txt")" "loaded_low_latency_flags_mismatch"

ck_eq "只校验 low 时 raw 不参与" "$(run_check "$T/policy_a.txt" 2 '')" "0"
ck_eq "不校验 flags 时直接通过" "$(run_check "$T/policy_a.txt" '' '')" "0"

echo ""
echo "############ 3. 无法识别 / 主输出缺失 ############"
printf 'totally unrelated output\n' > "$T/policy_bad.txt"
: > "$T/flinger_bad.txt"
awk -v expected_low=2 -f "$CHECKER" "$T/policy_bad.txt" "$T/flinger_bad.txt" >/dev/null 2>"$T/reason.txt"
ck_eq "格式不认识时失败" "$?" "1"
ck_eq "原因 policy_format_unrecognized" "$(cat "$T/reason.txt")" "policy_format_unrecognized"

cat > "$T/policy_nop.txt" <<'P'
  MixPorts:
  1. Handle: 15
     Output MixPorts:
       1. "low_latency_out"; flags 0x00000006
P
awk -v expected_low=2 -f "$CHECKER" "$T/policy_nop.txt" "$T/flinger.txt" >/dev/null 2>"$T/reason.txt"
ck_eq "无主输出时失败" "$?" "1"
ck_eq "原因 primary_output_not_ready" "$(cat "$T/reason.txt")" "primary_output_not_ready"

echo ""
echo "############ 4. 就绪结果的分类语义（源码级检查）############"
RT="$HERE/../webui/runtime.sh"
AR="$HERE/../webui/audio_ready.sh"
if grep -q 'loaded_low_latency_flags_mismatch|loaded_raw_flags_mismatch' "$AR" && \
   grep -q 'audioserver_not_running) return 0' "$AR"; then
  ok "flags 不符与服务未运行被归为致命（会回滚）"
else
  bad "致命原因分类不完整"
fi
if grep -q 'policy_format_unrecognized\|audio_policy_unavailable' "$AR"; then
  ok "读不到/格式不认不被当作致命"
else
  bad "缺少非致命原因的处理"
fi
if grep -q 'audio_ready_is_fatal' "$RT"; then
  ok "runtime.sh 使用了致命性判定"
else
  bad "runtime.sh 没有引用致命性判定"
fi
if grep -q 'prepare_patch 1 1 0' "$RT"; then
  ok "sound 模式只摘 FAST（保留 RAW）"
else
  bad "prepare_patch 参数不是 1 1 0"
fi
if grep -q 'audio_ready.sh missing; readiness verification disabled' "$RT"; then
  ok "audio_ready.sh 缺失时降级而不中断切换"
else
  bad "缺少 audio_ready.sh 缺失时的降级分支"
fi

echo ""
echo "############ 结果 ############"
echo "  通过 $pass，失败 $fail"
rm -rf "$T"
[ "$fail" = "0" ]
