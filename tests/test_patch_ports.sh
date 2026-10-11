#!/system/bin/sh
# patch_ports.awk 的行为测试（有界编辑器：正常改、异常一律 fail-closed）
SH=/system/bin/sh
AWK=${1:-$(dirname "$0")/../webui/patch_ports.awk}
T=/data/local/tmp/pt
rm -rf "$T"; mkdir -p "$T"

pass=0; fail=0
chk() { # chk <描述> <期望: ok|err> <实际rc> [stdout检查]
  d="$1"; want="$2"; rc="$3"; note="$4"
  if [ "$want" = "ok" ]; then
    if [ "$rc" = "0" ]; then pass=$((pass+1)); printf '  ✓ %s\n' "$d"
    else fail=$((fail+1)); printf '  ✗ %s (期望成功，rc=%s)\n' "$d" "$rc"; fi
  else
    if [ "$rc" != "0" ]; then pass=$((pass+1)); printf '  ✓ %s\n' "$d"
    else fail=$((fail+1)); printf '  ✗ %s (期望失败，却成功)\n' "$d"; fi
  fi
}

echo "############ 1. 正常场景 ############"

# 完整的 mixPorts 片段（AOSP 风格，含其它端口，确保不被误改）
cat > "$T/base.xml" <<'XEOF'
<audioPolicyConfiguration>
  <mixPorts>
    <mixPort name="low_latency_out" role="source" flags="FAST|PRIMARY">
    </mixPort>
    <mixPort name="deep_buffer_out" role="source" flags="DEEP_BUFFER">
    </mixPort>
    <mixPort name="raw_out" role="source" flags="FAST|RAW">
    </mixPort>
  </mixPorts>
</audioPolicyConfiguration>
XEOF

awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/base.xml" > "$T/out.xml" 2>"$T/err.txt"
chk "标准配置摘 FAST" ok $?
echo "     low_latency_out -> $(grep -oE 'name="low_latency_out"[^>]*flags="[^"]*"' "$T/out.xml")"
echo "     raw_out         -> $(grep -oE 'name="raw_out"[^>]*flags="[^"]*"' "$T/out.xml")"
echo "     deep_buffer_out -> $(grep -oE 'name="deep_buffer_out"[^>]*flags="[^"]*"' "$T/out.xml")"

# 空格分隔 + 单引号 + 多行标签
cat > "$T/base2.xml" <<'XEOF'
<mixPorts>
  <mixPort
      name='low_latency_out'
      role='source'
      flags='FAST PRIMARY'>
  </mixPort>
  <mixPort name='raw_out' role='source' flags='RAW FAST'></mixPort>
</mixPorts>
XEOF
awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/base2.xml" > "$T/out2.xml" 2>"$T/err2.txt"
chk "多行/单引号/空格分隔" ok $?
grep -oE "name='(low_latency_out|raw_out)'" "$T/out2.xml" | sed 's/^/     /'
sed -n '/low_latency_out/,/mixPort>/p' "$T/out2.xml" | grep -i flags | sed 's/^/     /'

# 注释里出现同名端口，不应被改
cat > "$T/base3.xml" <<'XEOF'
<mixPorts>
  <!-- <mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/> -->
  <mixPort name="low_latency_out" role="source" flags="PRIMARY"></mixPort>
  <mixPort name="raw_out" role="source" flags="RAW"></mixPort>
</mixPorts>
XEOF
awk -v remove_fast_low=0 -v remove_fast_raw=0 -v remove_raw=0 -f "$AWK" "$T/base3.xml" > "$T/out3.xml" 2>/dev/null
chk "全 0 参数（不应改动，有无变化交由调用方判断）" ok $?
if grep -q 'FAST PRIMARY"/> -->' "$T/out3.xml"; then echo "     ✓ 注释内端口未被改动"; else echo "     ✗ 注释被改动"; fi

echo ""
echo "############ 2. 失败场景（必须 fail-closed、stdout 为空）############"
t_err() {
  d="$1"; shift
  "$@" > "$T/e.out" 2> "$T/e.err"
  rc=$?
  sz=$(wc -c < "$T/e.out" | tr -d ' ')
  if [ "$rc" != "0" ] && [ "$sz" = "0" ]; then
    pass=$((pass+1)); printf '  ✓ %-34s rc=%s stdout=0  原因=%s\n' "$d" "$rc" "$(head -1 $T/e.err)"
  else
    fail=$((fail+1)); printf '  ✗ %-34s rc=%s stdout=%s（应失败且无输出）\n' "$d" "$rc" "$sz"
  fi
}

printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/></mixPorts>\n' > "$T/missing_raw.xml"
t_err "缺少 raw_out 端口" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/missing_raw.xml"

printf '<mixPorts><mixPort name="low_latency_out" role="sink" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/wrong_role.xml"
t_err "端口 role 不是 source" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/wrong_role.xml"

printf '<mixPorts><mixPort name="low_latency_out" role="source"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/nof.xml"
t_err "缺 flags 属性" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/nof.xml"

printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/dup.xml"
t_err "重复端口（low_latency_out 两次）" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/dup.xml"

printf '<!DOCTYPE x><mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/doctype.xml"
t_err "含 DOCTYPE/XML 声明" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/doctype.xml"

printf '<mixPorts><!-- 未闭合注释 <mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/cmt.xml"
t_err "未闭合注释" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/cmt.xml"

printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/ok.xml"
t_err "参数不是 0/1" awk -v remove_fast_low=2 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/ok.xml"

printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/nomix.xml"
sed -i 's/<mixPorts>/<notMixPorts>/' "$T/nomix.xml"
t_err "没有 mixPorts 容器" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/nomix.xml"

# 已摘过 FAST 的配置再摘一次（防止二次改写）
printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="PRIMARY"/><mixPort name="raw_out" role="source" flags="RAW"/></mixPorts>\n' > "$T/done.xml"
t_err "已摘过 FAST（重复摘）" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/done.xml"

# 未知 flag
printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY WEIRD"/><mixPort name="raw_out" role="source" flags="FAST RAW"/></mixPorts>\n' > "$T/weird.xml"
t_err "未知 flag 组合" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/weird.xml"

# raw_out 带 PRIMARY 属异常
printf '<mixPorts><mixPort name="low_latency_out" role="source" flags="FAST PRIMARY"/><mixPort name="raw_out" role="source" flags="FAST RAW PRIMARY"/></mixPorts>\n' > "$T/rawp.xml"
t_err "raw_out 意外带 PRIMARY" awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 -f "$AWK" "$T/rawp.xml"

echo ""
echo "############ 3. 幂等与可逆 ############"
# 只摘 low_latency 的 FAST，raw_out 保持原样
awk -v remove_fast_low=1 -v remove_fast_raw=0 -v remove_raw=0 -f "$AWK" "$T/base.xml" > "$T/o4.xml" 2>/dev/null
chk "只摘 low_latency 的 FAST" ok $?
echo "     raw_out 应保持 FAST|RAW -> $(grep -oE 'name="raw_out"[^>]*flags="[^"]*"' "$T/o4.xml")"
# 只摘 raw_out 的 RAW（不动 FAST）
awk -v remove_fast_low=0 -v remove_fast_raw=0 -v remove_raw=1 -f "$AWK" "$T/base.xml" > "$T/o5.xml" 2>/dev/null
chk "只摘 raw_out 的 RAW" ok $?
echo "     raw_out -> $(grep -oE 'name="raw_out"[^>]*flags="[^"]*"' "$T/o5.xml")"
# 字节保真：除 flags 外应完全相同（比较行数与总长度差）
b=$(wc -c < "$T/base.xml" | tr -d ' '); a=$(wc -c < "$T/o4.xml" | tr -d ' ')
echo "     原始 $b 字节 -> 改后 $a 字节（差值应等于摘掉的 'FAST|' 长度 5）"
echo "     其它端口是否原样: $(grep -c 'deep_buffer_out" role="source" flags="DEEP_BUFFER"' "$T/o4.xml") 处"

echo ""
echo "############ 结果 ############"
echo "  通过: $pass   失败: $fail"
rm -rf "$T"
[ "$fail" = "0" ]
