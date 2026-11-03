#!/bin/sh
# lowlat.sh 主机侧测试：只测配置解析与保存，不测真实 chrt（那必须真机）。
# 覆盖：白名单 CSV 解析、only_whitelist 强制为 1、参数校验、保存时保留白名单。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/../webui/bin"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_ll_test)
rm -rf "$T"; mkdir -p "$T/mod/state" "$T/mod/bin"
trap 'rm -rf "$T"' EXIT

M=$T/mod
cp "$BIN/runtime.sh" "$BIN/lowlat.sh" "$BIN/sampling.sh" "$M/bin/"
MODDIR=$M
BOOT_ID=test-boot
. "$M/bin/runtime.sh"
. "$M/bin/sampling.sh"
. "$M/bin/lowlat.sh"

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }

echo "############ 1. 配置解析 ############"
cat > "$MODDIR/lowlat.conf" <<'EOF'
enabled=1
only_whitelist=0
hal_priority=20
audio_priority=16
app_priority=15
whitelist=com.x.one,com.y.two
revision=aaa
EOF
ll_read_config; RC=$?
ck "解析成功" "$RC" "0"
ck "enabled" "$LL_ENABLED" "1"
ck "only_whitelist 被强制为 1" "$LL_ONLY" "1"
ck "hal" "$LL_HAL" "20"
ck "whitelist 原样保留" "$LL_WHITE" "com.x.one,com.y.two"

echo ""
echo "############ 2. 参数校验 ############"
ll_valid 1 1 20 16 15 'com.a,com.b'; ck "合法配置通过" "$?" "0"
ll_valid 2 1 20 16 15 ''; ck "enabled=2 被拒" "$?" "1"
ll_valid 1 1 0 16 15 ''; ck "优先级 0 被拒" "$?" "1"
ll_valid 1 1 100 16 15 ''; ck "优先级 100 被拒" "$?" "1"
ll_valid 1 1 20 16 15 'bad name'; ck "非法包名被拒" "$?" "1"
ll_valid 1 1 20 16 15 'com.a,,com.b'; ck "空条目被拒" "$?" "1"
ll_valid 1 1 20 16 15 '-'; ck "空名单用 - 表示" "$?" "0"

echo ""
echo "############ 3. 保存保留白名单 ############"
printf 'native\n' > "$MODDIR/state/applied"
ll_save 0 25 17 16 >/dev/null 2>&1; RC=$?
ck "保存成功" "$RC" "0"
ck "hal 已更新" "$(sed -n 's/^hal_priority=//p' "$MODDIR/lowlat.conf")" "25"
ck "audio 已更新" "$(sed -n 's/^audio_priority=//p' "$MODDIR/lowlat.conf")" "17"
ck "app 已更新" "$(sed -n 's/^app_priority=//p' "$MODDIR/lowlat.conf")" "16"
ck "白名单未丢失" "$(sed -n 's/^whitelist=//p' "$MODDIR/lowlat.conf")" "com.x.one,com.y.two"

echo ""
echo "############ 4. 坏参数不落盘 ############"
BEFORE=$(cat "$MODDIR/lowlat.conf")
ll_save 1 0 16 15 >/dev/null 2>&1; RC=$?
ck "非法优先级返回失败" "$RC" "1"
ck "文件未被改写" "$(cat "$MODDIR/lowlat.conf")" "$BEFORE"

echo ""
echo "############ 5. 状态输出 ############"
O=$(ll_status)
ckc "含 enabled" "$O" "enabled=0"
ckc "含 whitelist" "$O" "whitelist=com.x.one,com.y.two"
ckc "含 daemon 状态" "$O" "ll_daemon="

echo ""
echo "############ 6. 坏配置文件被拒 ############"
printf 'enabled=1\nhal_priority=0\nwhitelist=\n' > "$MODDIR/lowlat.conf"
ll_read_config; ck "hal=0 使解析失败" "$?" "1"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
