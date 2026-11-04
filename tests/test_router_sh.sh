#!/bin/sh
# router.sh 主机侧测试：用临时目录替代模块目录，验证两个名单的读写、校验与互斥迁移。
# 不依赖设备上的 dumpsys/ps（status 里的探测失败时按 0/1 安全返回）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RS="$HERE/../webui/bin/router.sh"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_router_test)
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }
ckn() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (不应包含 %s)\n' "$1" "$3" ;; *) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; esac; }

setup() {
  M=$T/mod
  rm -rf "$M"; mkdir -p "$M/zygisk"
  printf 'hal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=\nrevision=initial\n' > "$M/lowlat.conf"
  printf 'x' > "$M/zygisk/arm64-v8a.so"
}

run() { MODDIR="$M" sh "$RS" "$@" 2>&1; }

echo "############ 1. 初始 status ############"
setup
O=$(run router-status)
ckc "杜比计数=0" "$O" "perapp_count=0"
ckc "低延迟计数=0" "$O" "wl_count=0"
ckc "负载存在" "$O" "perapp_payload=1"
ckc "无 enable 字段" "$O" "ok=1"
ckn "不再暴露总开关" "$O" "perapp_enabled"
ckn "不再暴露低延迟开关" "$O" "wl_enabled"
# 空文件不算"内置"：避免复制失败留下 0 字节 .so 时误报
: > "$M/zygisk/arm64-v8a.so"
O=$(run router-status)
ckc "空负载文件不算内置" "$O" "perapp_payload=0"
printf 'x' > "$M/zygisk/arm64-v8a.so"

echo ""
echo "############ 2. 音效名单增删 ############"
O=$(run perapp-add com.a.one)
ckc "添加返回 ok" "$O" "ok=1"
ck "文件含新增项" "$(grep -c '^app=com.a.one$' "$M/perapp.conf")" "1"
ck "enabled 默认写入 1" "$(grep '^enabled=' "$M/perapp.conf")" "enabled=1"
O=$(run perapp-add com.a.one)
ck "重复添加不产生重复行" "$(grep -c '^app=com.a.one$' "$M/perapp.conf")" "1"
O=$(run perapp-del com.a.one)
ckc "删除返回 ok" "$O" "ok=1"
ck "文件已移除" "$(grep -c 'com.a.one' "$M/perapp.conf")" "0"

echo ""
echo "############ 3. 低延迟名单写进 lowlat.conf ############"
O=$(run wl-add com.b.one)
ckc "添加返回 ok" "$O" "ok=1"
ckc "白名单已写入" "$O" "ok=1"
ck "whiteist 为 CSV" "$(grep '^whitelist=' "$M/lowlat.conf")" "whitelist=com.b.one"
O=$(run wl-add com.b.two)
ck "第二条追加" "$(grep '^whitelist=' "$M/lowlat.conf")" "whitelist=com.b.one,com.b.two"
ck "没有残留 config.toml" "$(test -e "$M/config.toml" && echo yes || echo no)" "no"
O=$(run wl-del com.b.one)
ck "删除后只剩一条" "$(grep '^whitelist=' "$M/lowlat.conf")" "whitelist=com.b.two"

echo ""
echo "############ 4. 名单互斥：自动迁移 ############"
setup
O=$(run perapp-add com.c.one)
O=$(run wl-add com.c.one)
ckc "加入低延迟后回显 moved_from" "$O" "moved_from=sound"
ck "音效名单已移除该包" "$(grep -c 'com.c.one' "$M/perapp.conf")" "0"
O=$(run perapp-add com.c.one)
ckc "加回音效后回显 moved_from" "$O" "moved_from=lowlat"
ck "低延迟白名单已清空" "$(grep '^whitelist=' "$M/lowlat.conf")" "whitelist="

echo ""
echo "############ 5. 白名单写入保留优先级 ############"
setup
cat > "$M/lowlat.conf" <<'EOF'
hal_priority=33
audio_priority=22
app_priority=11
whitelist=
revision=test
EOF
O=$(run wl-add com.d.one)
ck "hal 保持 33" "$(grep '^hal_priority=' "$M/lowlat.conf")" "hal_priority=33"
ck "audio 保持 22" "$(grep '^audio_priority=' "$M/lowlat.conf")" "audio_priority=22"
ck "app 保持 11" "$(grep '^app_priority=' "$M/lowlat.conf")" "app_priority=11"
ckc "白名单写入" "$(cat "$M/lowlat.conf")" "whitelist=com.d.one"

echo ""
echo "############ 6. 包名校验 ############"
for bad in '' 'a b' 'a;b' '1abc' '.x' 'a.' 'a..b'; do
  O=$(run perapp-add "$bad")
  ckc "拒绝 [${bad}]" "$O" "error=bad_package"
  O=$(run wl-add "$bad")
  ckc "低延迟同样拒绝 [${bad}]" "$O" "error=bad_package"
done

echo ""
echo "############ 7. 已移除的开关动作 ############"
O=$(run perapp-enable 1)
ckc "perapp-enable 已不存在" "$O" "error=bad_action"

echo ""
echo "############ 8. 未知动作 ############"
O=$(run what-ever)
ckc "返回 bad_action" "$O" "error=bad_action"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
