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

MOD=/data/adb/modules/hyperaudio
MODEFILE=$MOD/mode
MSW=$MOD/bin/mode_switch.sh
SH=/system/bin/sh

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

# 真正执行切换（apply 内部会改写端口标志、启停守护进程、重启 audioserver）
$SH "$MSW" apply "$NEXT" >/dev/null 2>&1

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
  exit 0
else
  say ""
  say "切换失败：模式文件未写入预期值（期望 $NEXT，实际 ${AFTER:-空}）"
  say "可打开 WebUI 查看详细状态。"
  exit 1
fi
