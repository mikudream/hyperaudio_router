#!/bin/sh
# router.sh 主机侧测试：用临时目录替代模块目录，验证两个名单的读写与校验。
# 不依赖设备上的 dumpsys/ps（那些分支只在 status 里，用 grep 失败也安全返回 0/1）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RS="$HERE/../webui/bin/router.sh"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_router_test)
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }

setup() {
  M=$T/mod
  rm -rf "$M"; mkdir -p "$M/zygisk"
  printf 'enabled=1\napp=com.a.one\n' > "$M/perapp.conf"
  cat > "$M/config.toml" <<'EOF'
enable = true
only_whitelist = true
audio_priority = 16
whitelist = [
    "com.b.one",
    "com.b.two",
]
EOF
  printf 'x' > "$M/zygisk/arm64-v8a.so"
}

run() { MODDIR="$M" sh "$RS" "$@" 2>&1; }

echo "############ 1. status 汇总 ############"
setup
O=$(run router-status)
ckc "含 enabled" "$O" "perapp_enabled=1"
ckc "杜比计数=1" "$O" "perapp_count=1"
ckc "杜比名单" "$O" "perapp_apps=com.a.one"
ckc "负载存在" "$O" "perapp_payload=1"
ckc "低延迟计数=2" "$O" "wl_count=2"
ckc "低延迟名单" "$O" "wl_apps=com.b.one,com.b.two"

echo ""
echo "############ 2. 杜比名单增删 ############"
O=$(run perapp-add com.a.two)
ckc "添加返回 ok" "$O" "ok=1"
ck "文件含新增项" "$(grep -c 'com.a.two' "$M/perapp.conf")" "1"
ck "enabled 保持" "$(grep '^enabled=' "$M/perapp.conf")" "enabled=1"
O=$(run perapp-del com.a.two)
ckc "删除返回 ok" "$O" "ok=1"
ck "文件已移除" "$(grep -c 'com.a.two' "$M/perapp.conf")" "0"
O=$(run perapp-add com.a.one)
ck "重复添加不产生重复行" "$(grep -c 'com.a.one' "$M/perapp.conf")" "1"

echo ""
echo "############ 3. 低延迟名单增删 ############"
O=$(run wl-add com.b.three)
ckc "添加返回 ok" "$O" "ok=1"
ck "文件含新增项" "$(grep -c 'com.b.three' "$M/config.toml")" "1"
ck "原有条目未被破坏" "$(grep -c 'com.b.two' "$M/config.toml")" "1"
O=$(run wl-del com.b.three)
ckc "删除返回 ok" "$O" "ok=1"
ck "文件已移除" "$(grep -c 'com.b.three' "$M/config.toml")" "0"

echo ""
echo "############ 4. 包名校验 ############"
for bad in '' 'a b' 'a;b' '1abc' '.x' 'a.' 'a..b'; do
  O=$(run perapp-add "$bad")
  ckc "拒绝 [${bad}]" "$O" "error=bad_package"
done
O=$(run wl-add 'bad name')
ckc "低延迟名单同样校验" "$O" "error=bad_package"

echo ""
echo "############ 5. enable 取值校验 ############"
O=$(run perapp-enable 2)
ckc "非法值被拒" "$O" "error=bad_value"
O=$(run perapp-enable 0)
ckc "关闭返回 ok" "$O" "ok=1"
ck "enabled 已写入 0" "$(grep '^enabled=' "$M/perapp.conf")" "enabled=0"

echo ""
echo "############ 6. 未知动作 ############"
O=$(run what-ever)
ckc "返回 bad_action" "$O" "error=bad_action"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
