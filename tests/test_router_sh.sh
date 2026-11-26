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
  rm -rf "$M"; mkdir -p "$M/zygisk" "$M/props" "$M/state"
  printf 'hal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=\nrevision=initial\n' > "$M/lowlat.conf"
  printf 'x' > "$M/zygisk/arm64-v8a.so"
}

mkdir -p "$T/bin"
cat > "$T/bin/setprop" <<'EOF'
#!/bin/sh
[ "${#2}" -le 80 ] || exit 1
if [ "${HA_PROP_FAIL_KEY:-}" = "$1" ] && [ ! -f "$HA_PROPS/failed-once" ]; then
  : > "$HA_PROPS/failed-once"
  exit 1
fi
printf '%s' "$2" > "$HA_PROPS/$1"
EOF
cat > "$T/bin/getprop" <<'EOF'
#!/bin/sh
if [ -f "$HA_PROPS/$1" ]; then cat "$HA_PROPS/$1"; fi
EOF
chmod +x "$T/bin/setprop" "$T/bin/getprop"
run() { PATH="$T/bin:$PATH" HA_PROPS="$M/props" MODDIR="$M" sh "$RS" "$@" 2>&1; }

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
echo '############ 9. 属性分片、容量与失败回滚 ############'
setup
long=$(awk 'BEGIN {printf "com.";for(i=0;i<116;i++)printf "x"}')
O=$(run perapp-add "$long")
ckc '120 字节包名接受' "$O" 'ok=1'
pointer=$(cat "$M/props/ha.perapp.app.active")
bank=${pointer##*.}
ck '第 0 槽恰为 80 字节' "$(wc -c < "$M/props/ha.perapp.app.$bank.0" | tr -d ' ')" '80'
ck '跨槽无损拼接' "$(cat "$M/props/ha.perapp.app.$bank.0" "$M/props/ha.perapp.app.$bank.1")" "$long"
ck '第 31 槽已清空' "$(cat "$M/props/ha.perapp.app.$bank.31")" '-'
cp "$M/perapp.conf" "$T/perapp.before"
cp "$M/lowlat.conf" "$T/lowlat.before"
HA_PROP_FAIL_KEY=ha.mmap_gate.active; export HA_PROP_FAIL_KEY
O=$(run wl-add "$long")
unset HA_PROP_FAIL_KEY
ckc '模拟第二次 active 提交失败' "$O" 'error=publish_failed'
ckn '属性失败不回显迁移成功' "$O" 'ok=1'
ck '音效原文件完整恢复' "$(cmp -s "$T/perapp.before" "$M/perapp.conf"; echo $?)" '0'
ck '低延迟原文件完整恢复' "$(cmp -s "$T/lowlat.before" "$M/lowlat.conf"; echo $?)" '0'
ck '先前 active 指针回滚' "$(cat "$M/props/ha.perapp.app.active")" "$pointer"
ckc '发布失败可在 status 查询' "$(run router-status)" 'config_publish=publish_failed'
O=$(run wl-add "$long")
ckc '撤销故障后可重试' "$O" 'moved_from=sound'
awk 'BEGIN {print "enabled=1";for(i=0;i<22;i++){printf "app=com.x%d",i;for(j=0;j<110;j++)printf "x";print ""}}' > "$M/perapp.conf"
cp "$M/perapp.conf" "$T/perapp.before"
O=$(run perapp-add com.over.capacity)
ckc '超容量有明确错误' "$O" 'error=property_capacity_exceeded'
ck '超容量不改文件' "$(cmp -s "$T/perapp.before" "$M/perapp.conf"; echo $?)" '0'

echo '############ 10. 首次发布失败的恢复与并发写入 ############'
setup
printf 'legacy.old.app' > "$M/props/ha.perapp.app.0"
HA_PROP_FAIL_KEY=ha.mmap_gate.active; export HA_PROP_FAIL_KEY
O=$(run perapp-add com.first.app)
unset HA_PROP_FAIL_KEY
ckc '首次发布失败明确返回' "$O" 'error=publish_failed'
ck '首次失败恢复空 active' "$(cat "$M/props/ha.perapp.app.active")" ''
ck '首次失败保留旧名单属性' "$(cat "$M/props/ha.perapp.app.0")" 'legacy.old.app'
O=$(run perapp-add com.first.app)
ckc '首次发布失败后可重试' "$O" 'ok=1'

setup
run perapp-add com.concurrent.one > "$T/out.one" &
pid1=$!
run perapp-add com.concurrent.two > "$T/out.two" &
pid2=$!
wait "$pid1"
wait "$pid2"
ckc '并发第一项成功' "$(cat "$T/out.one")" 'ok=1'
ckc '并发第二项成功' "$(cat "$T/out.two")" 'ok=1'
ck '并发第一项保留' "$(grep -c '^app=com.concurrent.one$' "$M/perapp.conf")" '1'
ck '并发第二项保留' "$(grep -c '^app=com.concurrent.two$' "$M/perapp.conf")" '1'

echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
