SKIPUNZIP=0

# ---------------- 安装环境 ----------------
[ "$BOOTMODE" = true ] || abort "请在 Magisk / KernelSU 管理器内安装，不支持 recovery。"

MODROOT=/data/adb/modules
OLD=$MODROOT/hyperaudio

# ---------------- 1. 依赖：管理器 busybox ----------------
# ha.sh 会 re-exec 管理器自带的 busybox，缺失时所有 WebUI 接口都会返回
# manager_busybox_missing，因此安装时就应当提醒。
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
  [ -x "$b" ] && { BB=$b; break; }
done
if [ -n "$BB" ]; then
  ui_print "- 依赖检查：busybox 可用（$BB）"
else
  ui_print "! 未找到管理器自带的 busybox"
  ui_print "! WebUI 接口将不可用（运行需要 /data/adb/ksu/bin/busybox 或 magisk）"
  ui_print "! 模块仍会安装，可稍后在管理器内修复后重新安装"
fi

# ---------------- 2. 重复实现：上游 3.0（id 为 hyperaudio_compat） ----------------
if [ -d "$MODROOT/hyperaudio_compat" ]; then
  ui_print "! 检测到另一套 HyperAudio（hyperaudio_compat）"
  ui_print "! 两者会同时修改音频端口配置与 aaudio 属性，互相覆盖"
  ui_print "! 建议先卸载 hyperaudio_compat 并重启后再使用本模块"
fi

# ---------------- 3. 其它可能冲突的音频模块 ----------------
# 只做提示，不阻止安装：这些模块与本模块都会改写端口配置或音频属性。
CONFLICTS=""
for d in "$MODROOT"/*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  case "$n" in hyperaudio|hyperaudio_compat|modules_update) continue ;; esac
  hit=0
  # 自带音频端口配置副本
  if [ -n "$(find "$d" -maxdepth 4 -name 'audio_module_config*.xml' 2>/dev/null | head -n 1)" ]; then
    hit=1
  fi
  # system.prop 里改写音频相关属性
  if [ "$hit" = 0 ] && [ -f "$d/system.prop" ]; then
    grep -qE '^(aaudio\.|vendor\.audio|persist\.vendor\.audio|af\.fast_track|ro\.audio)' "$d/system.prop" 2>/dev/null && hit=1
  fi
  [ "$hit" = 1 ] && CONFLICTS="$CONFLICTS $n"
done
if [ -n "$CONFLICTS" ]; then
  ui_print "! 以下模块同样会修改音频配置/属性，可能与本模块冲突："
  for n in $CONFLICTS; do ui_print "!   - $n"; done
  ui_print "! 若音效或延迟表现异常，请先只保留其中一个再测试"
fi

# ---------------- 4. 覆盖升级：保留配置、清理中断状态 ----------------
# 旧版（本模块历史版本）用 state/*.xml 与 config.toml；新版用 mode/state 结构。
# 只保留能对得上的配置，其余交给新版重建，避免因模式不同而中止安装。
if [ -d "$OLD" ]; then
  for f in boot.conf sound.conf lowlat.conf; do
    [ -f "$OLD/$f" ] && cp -f "$OLD/$f" "$MODPATH/$f" 2>/dev/null
  done
  ui_print "- 覆盖升级：已保留可复用的配置文件"

  # 旧版若停在非原生模式，安装会替换模块内容，其 bind 挂载在重启前可能悬空。
  oldmode=$(cat "$OLD/mode" 2>/dev/null)
  if [ -n "$oldmode" ] && [ "$oldmode" != native ]; then
    ui_print "! 旧版处于 $oldmode 模式，安装后请立即重启"
    ui_print "! 重启前音频配置可能处于半更新状态"
  fi
fi

# 清掉可能遗留的中断事务与挂载归属标记：新版会重新建立，继承它们只会触发回滚
for stale in state/transaction state/owned state/boot.pending state/boot.failure; do
  [ -e "$MODPATH/$stale" ] && rm -f "$MODPATH/$stale" 2>/dev/null
done

# ---------------- 5. 新结构初始化 ----------------
mkdir -p "$MODPATH/state" || abort "无法创建 state 目录。"
[ -f "$MODPATH/mode" ] || printf 'native\n' > "$MODPATH/mode"
chmod 0644 "$MODPATH/mode" 2>/dev/null

# Leave webroot's permissions/context to the manager (KernelSU handles it specially).
set_perm_recursive "$MODPATH/bin" 0 0 0755 0644
for f in "$MODPATH"/*.sh "$MODPATH"/bin/*.sh; do
  [ -f "$f" ] && set_perm "$f" 0 0 0755
done

# ---------------- 6. 安装完成提示 ----------------
ui_print "- HyperAudio Switch 3.0 正式版"
ui_print "- 支持 Miuix / Material 3 界面与可选悬浮底栏"
ui_print "- 支持原生与音效模式，可调整低延迟和音频设置"
ui_print "- 可选择开机模式，已保存的设置会保留"
ui_print "- 启用模块后，日常切换无需重启手机；切换后请重新打开游戏"
ui_print "- 部分游戏在音效模式下可能出现电流声、破音或无声"
ui_print "- 安装完成后，请按管理器提示启用模块"
ui_print "- KernelSU 可直接打开 WebUI；Magisk 请使用兼容的 WebUI 管理器"
