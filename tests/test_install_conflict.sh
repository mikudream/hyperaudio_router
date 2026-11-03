#!/bin/sh
# customize.sh 的互斥逻辑主机侧测试：
#   1) 干净环境可以安装
#   2) 已装全局版（HyperAudio Switch）必须中止
#   3) 已装上游客（hyperaudio_compat）必须中止
#   4) 升级本分支旧版（名称含 Router）必须放行并保留名单
#
# 做法：桩掉管理器的 ui_print/abort/set_perm*，用 HA_MODROOT 指到临时目录，
# 因此测的是 customize.sh 的真实分支，而不是复制品。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../assets/customize.sh"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_install_test)
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }

run_install() {
  MR=$T/modules
  MP=$T/modpath
  rm -rf "$MR" "$MP"
  mkdir -p "$MR" "$MP/bin"
  case "$1" in
    general)
      mkdir -p "$MR/hyperaudio"
      printf 'id=hyperaudio\nname=HyperAudio Switch\nversion=2.0.1\n' > "$MR/hyperaudio/module.prop"
      ;;
    compat)
      mkdir -p "$MR/hyperaudio_compat"
      printf 'id=hyperaudio_compat\nname=HyperAudio Switch 3.0\n' > "$MR/hyperaudio_compat/module.prop"
      ;;
    router)
      mkdir -p "$MR/hyperaudio"
      printf 'id=hyperaudio\nname=HyperAudioRouter\nversion=2.2.0\n' > "$MR/hyperaudio/module.prop"
      printf 'enabled=1\nonly_whitelist=1\nhal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=com.keep.me\n' > "$MR/hyperaudio/lowlat.conf"
      ;;
    broken)
      mkdir -p "$MR/hyperaudio"
      ;;
  esac
  cat > "$T/wrap.sh" <<'EOF'
BOOTMODE=true
ui_print() { printf 'UI:%s\n' "$*"; }
abort() { printf 'ABORT:%s\n' "$*"; exit 3; }
set_perm() { :; }
set_perm_recursive() { :; }
. "$SRC"
EOF
  SRC="$SRC" MODPATH="$MP" HA_MODROOT="$MR" sh "$T/wrap.sh" 2>&1
}

echo "############ 1. 干净环境 ############"
O=$(run_install clean); RC=$?
ck "退出码 0" "$RC" "0"
ckc "生成 lowlat.conf" "$(cat "$T/modpath/lowlat.conf" 2>/dev/null)" "enabled=1"
ckc "生成 perapp.conf" "$(cat "$T/modpath/perapp.conf" 2>/dev/null)" "enabled=1"

echo ""
echo "############ 2. 已装全局版：必须中止 ############"
O=$(run_install general); RC=$?
ck "退出码 3" "$RC" "3"
ckc "提示全局版" "$O" "全局版"
ckc "要求卸载" "$O" "卸载"
ck "未写入配置文件" "$(test -f "$T/modpath/lowlat.conf" && echo yes || echo no)" "no"

echo ""
echo "############ 3. 已装上游 3.0（hyperaudio_compat）：必须中止 ############"
O=$(run_install compat); RC=$?
ck "退出码 3" "$RC" "3"
ckc "提示 hyperaudio_compat" "$O" "hyperaudio_compat"

echo ""
echo "############ 4. 升级本分支旧版：放行并保留名单 ############"
O=$(run_install router); RC=$?
ck "退出码 0" "$RC" "0"
ckc "保留白名单" "$(cat "$T/modpath/lowlat.conf" 2>/dev/null)" "com.keep.me"
ck "未中止安装" "$(printf '%s' "$O" | grep -c 'ABORT' || true)" "0"

echo ""
echo "############ 5. 目录存在但无 module.prop：告警后继续 ############"
O=$(run_install broken); RC=$?
ck "退出码 0" "$RC" "0"
ckc "给出告警" "$O" "读不到模块名"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
