#!/bin/sh
# action.sh / uninstall.sh 的主机侧测试。
# 这两个脚本面向用户或关系到"卸载是否干净"，改错代价高，所以锁住行为：
#   1) 切换成功后必须**区分**"已确认生效"与"未能确认"，不能一律说成功
#   2) 切换失败必须返回非零，并把 runtime 的具体原因翻成人话
#   3) 卸载时 recover 失败必须透传退出码，且不能打印"已恢复"
#   4) 卸载会清掉只属于本模块的 perapp.conf
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ACTION="$HERE/../webui/action.sh"
UNINST="$HERE/../webui/uninstall.sh"
T=$(mktemp -d 2>/dev/null || echo /tmp/ha_au_test)
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }
ckc() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s (未包含: %s)\n' "$1" "$3" ;; esac; }
ckn() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (不应包含: %s)\n' "$1" "$3" ;; *) pass=$((pass+1)); printf '  OK   %s\n' "$1" ;; esac; }

setup() {
  M=$T/mod
  rm -rf "$M"; mkdir -p "$M/bin" "$M/state"
  cat > "$M/module.prop" <<'EOF'
id=hyperaudio
name=音频模式切换器
version=0.4.7
mode.sound=音效模式
mode.fast=低延迟模式
EOF
  printf 'fast\n' > "$M/mode"
  printf 'x\n' > "$M/perapp.conf"
}

# 伪装 runtime.sh：按 STUB_MODE 产出不同输出
stub_runtime() {
  cat > "$M/bin/runtime.sh" <<'EOF'
#!/system/bin/sh
case "$1" in
  apply)
    if [ "${STUB_FAIL:-0}" = "1" ]; then
      echo "error=${STUB_ERR:-apply_failed_restored_native}"
      exit 1
    fi
    printf '%s\n' "$2" > "$(dirname "$0")/../mode"
    echo "ok=1"
    echo "mode=$2"
    [ -n "${STUB_AR:-}" ] && echo "audio_ready=${STUB_AR}"
    [ -n "${STUB_VF:-}" ] && echo "verified=${STUB_VF}"
    exit 0 ;;
  recover) exit "${STUB_RC:-0}" ;;
esac
exit 0
EOF
  chmod 0755 "$M/bin/runtime.sh"
}

echo "############ 1. 切换成功：区分就绪结论 ############"
setup; stub_runtime
O=$(HA_MOD="$M" HA_SH=sh STUB_AR=passed STUB_VF=1 sh "$ACTION" 2>&1); RC=$?
ck  "退出码 0" "$RC" "0"
ckc "报告已切换" "$O" "已切换到 音效模式"
ckc "已确认加载时给出明确结论" "$O" "已确认加载当前配置"
ckc "更新了简介" "$O" "模块简介已更新"
ck  "模式文件已写入" "$(cat "$M/mode")" "sound"

O=$(HA_MOD="$M" HA_SH=sh STUB_AR=failed sh "$ACTION" 2>&1); RC=$?
ck  "失败态退出码仍为 0（模式已切换）" "$RC" "0"
ckc "校验未通过时不谎称生效" "$O" "校验未通过"
ckn "校验未通过时不说已确认" "$O" "已确认加载当前配置"

O=$(HA_MOD="$M" HA_SH=sh STUB_AR="" STUB_VF="" sh "$ACTION" 2>&1); RC=$?
ckc "无就绪信息时说未能确认" "$O" "未能确认"

echo ""
echo "############ 2. 切换失败：非零退出 + 人话 ############"
setup; stub_runtime
O=$(HA_MOD="$M" HA_SH=sh STUB_FAIL=1 STUB_ERR=bind_mount_denied sh "$ACTION" 2>&1); RC=$?
ck  "返回非零" "$RC" "1"
ckc "翻译成可读原因" "$O" "挂载被拒"
ckn "失败时不打印已切换成功" "$O" "已切换到"
ck  "模式文件未被改" "$(cat "$M/mode")" "fast"

O=$(HA_MOD="$M" HA_SH=sh STUB_FAIL=1 STUB_ERR=overlay_changed_by_another_module sh "$ACTION" 2>&1)
ckc "冲突场景有专门提示" "$O" "已被其他模块改动"

O=$(HA_MOD="$M" HA_SH=sh STUB_FAIL=1 STUB_ERR=port_patch_rejected_unsupported_flag sh "$ACTION" 2>&1)
ckc "端口拒绝时带出子原因" "$O" "unsupported_flag"

echo ""
echo "############ 3. 卸载：recover 失败必须透传 ############"
setup; stub_runtime
O=$(HA_MOD="$M" HA_SH=sh STUB_RC=0 sh "$UNINST" 2>&1); RC=$?
ck  "recover 成功时退出 0" "$RC" "0"
ckc "报告已恢复" "$O" "系统原始音频配置已恢复"
ck  "清掉了 perapp.conf" "$([ -f "$M/perapp.conf" ] && echo 在 || echo 无)" "无"

setup; stub_runtime
O=$(HA_MOD="$M" HA_SH=sh STUB_RC=3 sh "$UNINST" 2>&1); RC=$?
ck  "recover 失败时透传退出码" "$RC" "3"
ckc "明确提示未完全成功" "$O" "清理未完全成功"
ckn "失败时不说已恢复" "$O" "系统原始音频配置已恢复"
ckc "提示重启确认" "$O" "请重启设备后确认"
ck  "perapp.conf 仍被清理" "$([ -f "$M/perapp.conf" ] && echo 在 || echo 无)" "无"

echo ""
echo "############ 4. 缺少 runtime.sh 时的行为 ############"
setup
O=$(HA_MOD="$M" HA_SH=sh sh "$ACTION" 2>&1); RC=$?
ck  "action 返回非零" "$RC" "1"
ckc "提示重新刷入" "$O" "找不到"

O=$(HA_MOD="$M" HA_SH=sh sh "$UNINST" 2>&1); RC=$?
ck  "uninstall 仍能正常结束" "$RC" "0"

echo ""
echo "############ 结果 ############"
printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
