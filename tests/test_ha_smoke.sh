#!/bin/sh
# v3.0 后端（ha.sh 及其依赖）的主机冒烟测试。
#
# 目的：在没有设备的情况下，尽早暴露"脚本拉起即崩"的问题——
#   缺少被 source 的文件、依赖不存在的命令、路径拼错、配置解析异常。
# 做法：造一个假 MODDIR（含 bin/ 与三个 conf），用 PATH 桩替换所有设备命令，
# 然后跑若干只读动作，断言退出码与输出形态。
#
# 注意：这里不验证音频行为（那必须真机），只验证"脚本能跑起来且不报错"。
#
# 注意：主机上用 HA_BOOT_ID / HA_BUSYBOX 两个开关绕过设备专属前置条件，
# 其余分支（清空 /proc、启动后台、状态汇总）保持与设备一致。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../webui/bin"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_smoke)
rm -rf "$T"; mkdir -p "$T/mod/bin" "$T/bin" "$T/tmp"
trap 'rm -rf "$T"' EXIT

M=$T/mod
cp "$SRC"/*.sh "$SRC"/*.awk "$M/bin/" 2>/dev/null
printf 'id=hyperaudio\nname=test\nversion=9.9.9\nversionCode=1\ndescription=test\n' > "$M/module.prop"
printf 'enabled=1\nonly_whitelist=1\nhal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=com.example.game\nrevision=test\n' > "$M/lowlat.conf"
printf 'enabled=1\napp=com.example.other\n' > "$M/perapp.conf"
mkdir -p "$M/state"
printf 'native\n' > "$M/state/applied"

# ---- 设备命令桩 ----
for c in resetprop setprop getprop killall chcon restorecon mv cp rm mkdir chmod ps logcat am dumpsys pidof id whoami uname base64 tar gzip; do
  case "$c" in
    getprop)
      cat > "$T/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  init.svc.audioserver) echo running ;;
  ro.product.device) echo testdev ;;
  *) echo "" ;;
esac
EOF
      ;;
    pidof)
      cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
case "$1" in
  audioserver) echo 1234 ;;
  hyper-audio) echo 2345 ;;
  *) exit 1 ;;
esac
EOF
      ;;
    dumpsys)
      cat > "$T/bin/dumpsys" <<'EOF'
#!/bin/sh
for a in "$@"; do svc=$a; done
case "$svc" in
  media.audio_policy)
    echo " Primary Output I/O handle: 13"
    echo '      1. "low_latency_out"; 0x0006 (AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST)'
    echo '      8. "raw_out"; 0x0104 (AUDIO_OUTPUT_FLAG_FAST|AUDIO_OUTPUT_FLAG_RAW)'
    ;;
  media.audio_flinger)
    echo "Output thread 0x1, name AudioOut_D"
    echo " I/O handle: 13"
    echo " HAL frame count: 1920"
    ;;
  *) echo "" ;;
esac
exit 0
EOF
      ;;
    id)
      cat > "$T/bin/id" <<'EOF2'
#!/bin/sh
case "$1" in
  -u) echo 0 ;;
  *) echo "uid=0(root) gid=0(root)" ;;
esac
EOF2
      ;;
    base64)
      cat > "$T/bin/base64" <<'EOF'
#!/bin/sh
exec /usr/bin/base64 "$@" 2>/dev/null || cat >/dev/null
EOF
      ;;
    *)
      printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"
      ;;
  esac
  chmod +x "$T/bin/$c"
done

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含 %s)\n' "$1" "$3" ;; esac; }
ckn() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (不应包含 %s)\n' "$1" "$3" ;; *) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; esac; }

# ha.sh 第一件事是 re-exec 管理器自带的 busybox（/data/adb/ksu/bin/busybox 或
# magisk 的）。主机上没有它，会直接返回 error=manager_busybox_missing。
# 这里用 HA_BUSYBOX=1 跳过 re-exec（脚本自己支持这个开关），保持其余逻辑不变。
run() {
  PATH="$T/bin:$PATH" MODDIR="$M" OUTFD=1 TMPDIR="$T/tmp" HA_BUSYBOX=1 HA_BOOT_ID=smoke-boot \
    sh "$M/bin/ha.sh" "$@" 2>&1
}

echo "############ 1. 只读动作能跑完且不报错 ############"
for act in status ll-status boot-status tuning theme diag-status; do
  O=$(run $act); RC=$?
  ck "$act 退出码 0" "$RC" "0"
  ckn "$act 无 'not found'" "$O" "not found"
  ckn "$act 无 'No such file'" "$O" "No such file"
  ckn "$act 无 'syntax error'" "$O" "syntax error"
done

echo ""
echo "############ 2. status 输出形态 ############"
O=$(run status)
ckc "含 key=value 结构" "$O" "="
ckn "不含未展开变量" "$O" '$MODDIR'

echo ""
echo "############ 3. 未知动作不应崩溃 ############"
O=$(run this-does-not-exist); RC=$?
ckc "给出用法提示而非崩溃" "$O" "usage:"

echo ""
echo "############ 4. 缺配置时仍能启动 ############"
rm -f "$M/lowlat.conf"
O=$(run status); RC=$?
ck "缺配置 running status 退出码 0" "$RC" "0"
ckn "缺配置不抛 'No such file'" "$O" "No such file"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
