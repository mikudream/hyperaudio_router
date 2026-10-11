#!/bin/sh
# 用真实 helper.sh 的 save 分支做严格校验测试。
# 做法：把 helper.sh 复制一份，**只替换路径常量**（MOD/TMP/系统解释器），
#       保存逻辑本身完全不变，因此测的是真实代码。
SRC=$(dirname "$0")/../webui/helper.sh
BASE=/tmp/ha_savetest
rm -rf "$BASE"; mkdir -p "$BASE/mod"

# 生成被测副本：只改路径
sed -e "s#^MOD=/data/adb/modules/hyperaudio#MOD=$BASE/mod#" \
    -e "s#^TMP=/data/local/tmp/hyperaudio_webui#TMP=$BASE/tmp#" \
    -e "s#^SH=/system/bin/sh#SH=sh#" \
    -e "s#/system/bin/sh#sh#g" \
    "$SRC" > "$BASE/helper.sh"

CONF="$BASE/mod/config.toml"
IN="$BASE/in.json"

mkconf() {
  cat > "$CONF" <<'EOF'
[daemon]
enable = true
only_whitelist = false
audio_priority = 16
hal_priority = 20
app_priority = 15
whitelist = [
    "com.android.cts.verifier",
    "org.flos.phira"
]
EOF
}

run_save() {
  mkconf
  printf '%s' "$2" > "$IN"
  before=$(md5sum "$CONF" | awk '{print $1}')
  out=$(sh "$BASE/helper.sh" save "$IN" 2>&1)
  rc=$?
  after=$(md5sum "$CONF" | awk '{print $1}')
  changed=no; [ "$before" != "$after" ] && changed=yes
  printf '  %-30s rc=%s 改了=%-3s %s\n' "$3" "$rc" "$changed" "$(printf '%s' "$out" | tr -d '\037')"
}

echo "=== 应当被拒绝，且配置文件必须保持不变 ==="
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"0","hal_priority":"20","app_priority":"15","whitelist":["com.a.b"]}' "优先级 0"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"100","hal_priority":"20","app_priority":"15","whitelist":["com.a.b"]}' "优先级 100"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"abc","hal_priority":"20","app_priority":"15","whitelist":["com.a.b"]}' "优先级 abc"
run_save x '{"enable":"yes","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b"]}' "布尔 yes"
run_save x '{"only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b"]}' "缺 enable"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b","rm -rf /"]}' "白名单含空格项"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b","$(touch /tmp/pwned)"]}' "白名单含命令替换"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b","a;b"]}' "白名单含分号"

echo ""
echo "=== 应当通过并落盘 ==="
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b","com.c.d"]}' "合法输入"
run_save x '{"enable":"false","only_whitelist":"true","audio_priority":"1","hal_priority":"99","app_priority":"50","whitelist":["com.a.b"]}' "边界 1/99/50"
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":[]}' "空白名单"

echo ""
echo "=== 落盘内容（最后一次=空白名单）==="
cat "$CONF" | sed 's/^/  /'

echo ""
echo "=== 无 whitelist 键时应保留原白名单 ==="
run_save x '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15"}' "无 whitelist 键"
grep -A4 'whitelist' "$CONF" | sed 's/^/  /'

echo ""
[ -e /tmp/pwned ] && echo "  ✗ 发生注入！" || echo "  ✓ 无注入发生"
rm -rf "$BASE"
