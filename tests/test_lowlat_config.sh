#!/bin/sh
# lowlat.sh 主机侧测试：只测配置解析与保存，不测真实 chrt（那必须真机）。
# 没有总开关：名单非空即调度；这里验证参数校验、保存时保留白名单。
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
# 主机没有 /system/bin/sh 与 dumpsys：把"拉起 daemon"和"跑一轮调度"换成空实现，
# 只验证保存路径本身（真实调度由真机测试覆盖）。
ll_ensure_daemon() { return 0; }
ll_tick_locked() { return 0; }

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }
ckn() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (不应包含 %s)\n' "$1" "$3" ;; *) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; esac; }

echo "############ 1. 配置解析（旧版 enabled 字段被忽略） ############"
cat > "$MODDIR/lowlat.conf" <<'EOF'
enabled=0
only_whitelist=0
hal_priority=20
audio_priority=16
app_priority=15
whitelist=com.x.one,com.y.two
revision=aaa
EOF
ll_read_config; RC=$?
ck "解析成功" "$RC" "0"
ck "hal" "$LL_HAL" "20"
ck "whitelist 原样保留" "$LL_WHITE" "com.x.one,com.y.two"
ck "不再有 enabled 变量" "${LL_ENABLED:-none}" "none"

echo ""
echo "############ 2. 参数校验 ############"
ll_valid 20 16 15 'com.a,com.b'; ck "合法配置通过" "$?" "0"
ll_valid 0 16 15 ''; ck "优先级 0 被拒" "$?" "1"
ll_valid 100 16 15 ''; ck "优先级 100 被拒" "$?" "1"
ll_valid 20 16 15 'bad name'; ck "非法包名被拒" "$?" "1"
ll_valid 20 16 15 'com.a,,com.b'; ck "空条目被拒" "$?" "1"
ll_valid 20 16 15 '-'; ck "空名单用 - 表示" "$?" "0"

echo ""
echo "############ 3. 保存只改优先级并保留白名单 ############"
printf 'native\n' > "$MODDIR/state/applied"
ll_save 25 17 16 >/dev/null 2>&1; RC=$?
ck "保存成功" "$RC" "0"
ck "hal 已更新" "$(sed -n 's/^hal_priority=//p' "$MODDIR/lowlat.conf")" "25"
ck "audio 已更新" "$(sed -n 's/^audio_priority=//p' "$MODDIR/lowlat.conf")" "17"
ck "app 已更新" "$(sed -n 's/^app_priority=//p' "$MODDIR/lowlat.conf")" "16"
ck "白名单未丢失" "$(sed -n 's/^whitelist=//p' "$MODDIR/lowlat.conf")" "com.x.one,com.y.two"
ckn "不再写 enabled" "$(cat "$MODDIR/lowlat.conf")" "enabled="
ckn "不再写 only_whitelist" "$(cat "$MODDIR/lowlat.conf")" "only_whitelist="

echo ""
echo "############ 4. 坏参数不落盘 ############"
BEFORE=$(cat "$MODDIR/lowlat.conf")
ll_save 0 16 15 >/dev/null 2>&1; RC=$?
ck "非法优先级返回失败" "$RC" "1"
ck "文件未被改写" "$(cat "$MODDIR/lowlat.conf")" "$BEFORE"

echo ""
echo "############ 5. 状态输出 ############"
O=$(ll_status)
ckc "含 hal" "$O" "hal_priority=25"
ckc "含 whitelist" "$O" "whitelist=com.x.one,com.y.two"
ckc "含 daemon 状态" "$O" "ll_daemon="
ckn "不再输出 enabled" "$O" "enabled="

echo ""
echo "############ 6. 坏配置文件被拒 ############"
printf 'hal_priority=0\nwhitelist=\n' > "$MODDIR/lowlat.conf"
ll_read_config; ck "hal=0 使解析失败" "$?" "1"

echo ""
echo "############ 7. module.prop 描述：空名单也不能写坏文件 ############"
printf 'id=hyperaudio\nname=test\nversion=1.0.0\ndescription=old\n' > "$MODDIR/module.prop"
printf 'enabled=1\n' > "$MODDIR/perapp.conf"
printf 'hal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=\nrevision=t\n' > "$MODDIR/lowlat.conf"
update_description
ck "描述只有一行" "$(grep -c '^description=' "$MODDIR/module.prop")" "1"
ck "文件行数不变" "$(wc -l < "$MODDIR/module.prop" | tr -d ' ')" "4"
ckc "空名单计 0 项" "$(grep '^description=' "$MODDIR/module.prop")" "音效名单 0 项"
ckc "低延迟空名单计 0 项" "$(grep '^description=' "$MODDIR/module.prop")" "低延迟名单 0 项"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
