#!/bin/sh
SRC=$(dirname "$0")/../webui/helper.sh
BASE=/tmp/ha_save2
rm -rf "$BASE"; mkdir -p "$BASE/mod"
sed -e "s#^MOD=/data/adb/modules/hyperaudio#MOD=$BASE/mod#" \
    -e "s#^TMP=/data/local/tmp/hyperaudio_webui#TMP=$BASE/tmp#" \
    -e "s#^SH=/system/bin/sh#SH=sh#" -e "s#/system/bin/sh#sh#g" "$SRC" > "$BASE/helper.sh"
CONF="$BASE/mod/config.toml"; IN="$BASE/in.json"
cat > "$CONF" <<'EOF'
[daemon]
enable = true
only_whitelist = false
audio_priority = 16
hal_priority = 20
app_priority = 15
whitelist = [
    "com.a.b",
    "com.c.d"
]

# 尾部注释：应被保留
# 第二行
EOF
printf '%s' '{"enable":"true","only_whitelist":"false","audio_priority":"16","hal_priority":"20","app_priority":"15","whitelist":["com.a.b","com.c.d"]}' > "$IN"

echo "=== 重复保存 5 次，观察行数/字节数是否增长 ==="
i=1
while [ $i -le 5 ]; do
  sh "$BASE/helper.sh" save "$IN" >/dev/null 2>&1
  printf '  第 %s 次: %s 行  %s 字节\n' "$i" "$(wc -l < "$CONF" | tr -d ' ')" "$(wc -c < "$CONF" | tr -d ' ')"
  i=$((i+1))
done

echo ""
echo "=== 最终内容 ==="
cat -A "$CONF" | sed 's/\$$/<EOL>/' | sed 's/^/  /'

echo ""
echo "=== 尾部注释是否保留、有无多余空行 ==="
grep -c '尾部注释' "$CONF" | sed 's/^/  注释出现次数: /'
echo "  文件末尾空行数: $(awk 'BEGIN{n=0} {if ($0 ~ /^[[:space:]]*$/) n++; else n=0} END{print n}' "$CONF")"

rm -rf "$BASE"
