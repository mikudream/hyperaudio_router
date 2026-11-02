#!/system/bin/sh
# ============================================================
# hyperaudio — KernelSU / Magisk 动作按钮
# ============================================================
# 在管理器的模块卡片上点「执行」，即在 音效模式 ↔ 低延迟模式 之间一键切换。
#
# 本脚本的 stdout 会被管理器捕获并展示，因此下面输出的是给人看的进度文案。
#
# FROM_WEBUI=1 时由 WebUI 调用，此时不要输出人类文案（WebUI 有自己的界面）。
# ============================================================

MOD=${HA_MOD:-/data/adb/modules/hyperaudio}
MODEFILE=$MOD/mode
# 模式状态机。0.4.5 里叫 mode_switch.sh，现在改名为 runtime.sh；保留旧名回退
# 只是为了让"只更新了部分文件"的中间状态也能工作。
MSW=$MOD/bin/runtime.sh
[ -f "$MSW" ] || MSW=$MOD/bin/mode_switch.sh
SH=${HA_SH:-/system/bin/sh}

quiet() { [ "$FROM_WEBUI" = "1" ]; }

say() { quiet || printf '%s\n' "$*"; }

# 取当前模式
M=$(cat "$MODEFILE" 2>/dev/null | tr -d ' \r\n')
case "$M" in fast) NEXT=sound ;; *) NEXT=fast ;; esac

# 用 module.prop 里的标记文案显示（与简介前缀同一份定义）
MS=$(sed -n 's/^mode\.sound=//p' "$MOD/module.prop" 2>/dev/null | head -1)
MF=$(sed -n 's/^mode\.fast=//p'  "$MOD/module.prop" 2>/dev/null | head -1)
[ -n "$MS" ] || MS='音效模式'
[ -n "$MF" ] || MF='低延迟模式'

if [ "$NEXT" = "sound" ]; then
  NEXT_TAG="$MS"
  FROM_TAG="$MF"
else
  NEXT_TAG="$MF"
  FROM_TAG="$MS"
fi

say "音频模式切换器"
say "当前：$FROM_TAG"
say ""
say "正在切换到 $NEXT_TAG ..."

if [ ! -f "$MSW" ]; then
  say ""
  say "失败：找不到 $MSW"
  say "请重新刷入本模块。"
  exit 1
fi

# 真正执行切换（apply 内部会改写端口标志、启停守护进程、必要时重启音频服务）
OUT=$($SH "$MSW" apply "$NEXT" 2>&1)

# 复核结果
AFTER=$(cat "$MODEFILE" 2>/dev/null | tr -d ' \r\n')
case "$AFTER" in sound|fast) ;; *) AFTER="" ;; esac

if [ "$AFTER" = "$NEXT" ]; then
  say ""
  if [ "$NEXT" = "fast" ]; then
    say "已切换到 $NEXT_TAG"
    say "音频端口已恢复 fast track，hyper-audio 守护进程已启动。"
    say "延迟最低、不卡顿；效果链被绕过，音效调音不生效。"
  else
    say "已切换到 $NEXT_TAG"
    say "音频端口已摘除 fast track，全部音频落入效果链。"
    say "Dolby / 按应用调音全局生效；可能出现音频卡顿。"
  fi
  say ""
  say "模块简介已更新，当前模式显示在简介开头。"
    # 就绪校验结论由 runtime.sh 的 apply 输出：只报"已切换"是不准确的，
    # 配置写进去了不等于音频框架加载了。
    _ar=$(printf '%s\n' "$OUT" | sed -n 's/^audio_ready=//p' | head -1)
    case "$_ar" in
      passed)
        say "音频框架：已确认加载当前配置。" ;;
      failed|timeout)
        say "音频框架：校验未通过（$_ar），模式已保留，原因见 WebUI。" ;;
      *)
        say "音频框架：未能确认（${_ar:-unknown}），配置已写入但不能断言已生效。" ;;
    esac
  exit 0
fi

# 失败：把 runtime.sh 给出的具体原因透传出来，而不是一律说"模式文件没写对"
ERR=$(printf '%s' "$OUT" | grep -m1 '^error=' | cut -d= -f2-)
say ""
case "$ERR" in
  no_tuning_config)
    say "切换失败：未找到提供音频端口配置的调音模块。"
    say "本模块的音效模式需要外部调音模块提供 audio_module_config_primary.xml。" ;;
  port_patch_rejected_*)
    say "切换失败：端口配置无法安全改写（${ERR#port_patch_rejected_}）。"
    say "该配置文件可能已被其他模块或工具改过。已回滚，未做任何改动。" ;;
  no_port_changes)
    say "切换失败：端口标志本来就是目标状态，无需补丁。"
    say "这通常说明配置已被别的模块改过。已回滚。" ;;
  bind_mount_denied|mount_not_visible)
    say "切换失败：无法把补丁叠加到系统路径（挂载被拒）。"
    say "已回滚，未做任何改动。" ;;
  apply_failed_restored_native)
    say "切换失败，已恢复为系统原始配置。"
    say "详情可在 WebUI 的 Debug 中查看。" ;;
  rollback_incomplete_reboot_required|unmount_failed_reboot_required)
    say "切换失败，且回滚未完全完成，需要重启手机。"
    say "重启后请在 WebUI 中重新选择模式。" ;;
  overlay_changed_by_another_module)
    say "切换失败：该挂载点已被其他模块改动，本模块不会强行覆盖。"
    say "请先在 WebUI 中执行「恢复」，或重启后再试。" ;;
  legacy_source_repair_failed)
    say "切换失败：调音模块的端口文件曾被旧版本改动，且修复失败。"
    say "请在该调音模块中恢复原始配置后重试。" ;;
  '')
    say "切换未完成，请在 WebUI 中检查当前模式。" ;;
  *)
    say "切换未完成：$ERR"
    say "可打开 WebUI 查看详细状态。" ;;
esac
exit 1
