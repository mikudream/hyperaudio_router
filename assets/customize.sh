SKIPUNZIP=0

# ---------------- 安装环境 ----------------
[ "$BOOTMODE" = true ] || abort "请在 Magisk / KernelSU 管理器内安装，不支持 recovery。"

MODROOT=${HA_MODROOT:-/data/adb/modules}
OLD=$MODROOT/hyperaudio

# ---------------- 0. 与全局版互斥 ----------------
# 本模块与全局版共用 id=hyperaudio：安装会直接覆盖同一个模块目录，两者无法共存。
# 全局版的特征是模块名不含 Router（HyperAudio Switch / 音频模式切换器），
# 或安装了上游 3.0 的 hyperaudio_compat。检测到就中止，避免静默覆盖。
if [ -d "$MODROOT/hyperaudio_compat" ]; then
  abort "检测到全局版 HyperAudio Switch 3.0（hyperaudio_compat）。HyperAudioRouter 不能与全局版共存，请先在管理器中卸载它并重启，再安装本模块。"
fi
if [ -d "$OLD" ]; then
  OLD_NAME=$(sed -n 's/^name=//p' "$OLD/module.prop" 2>/dev/null | head -n 1)
  case "$OLD_NAME" in
    *Router*) : ;;
    '') ui_print "! 已存在同名模块目录但读不到模块名，按覆盖升级继续" ;;
    *) abort "检测到全局版「$OLD_NAME」已安装。HyperAudioRouter 不能与全局版共存，请先在管理器中卸载它并重启，再安装本模块。" ;;
  esac
fi

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

# ---------------- 2. 与其它音频模块的冲突提示 ----------------
# 只做提示，不阻止安装：这些模块同样会改写端口配置或音频属性。
CONFLICTS=""
for d in "$MODROOT"/*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  case "$n" in hyperaudio|hyperaudio_compat|modules_update) continue ;; esac
  hit=0
  if [ -n "$(find "$d" -maxdepth 4 -name 'audio_module_config*.xml' 2>/dev/null | head -n 1)" ]; then
    hit=1
  fi
  if [ "$hit" = 0 ] && [ -f "$d/system.prop" ]; then
    grep -qE '^(aaudio\.|vendor\.audio|persist\.vendor\.audio|af\.fast_track|ro\.audio)' "$d/system.prop" 2>/dev/null && hit=1
  fi
  [ "$hit" = 1 ] && CONFLICTS="$CONFLICTS $n"
done
if [ -n "$CONFLICTS" ]; then
  ui_print "! 以下模块同样会修改音频配置/属性，可能与本模块冲突："
  for n in $CONFLICTS; do ui_print "!   - $n"; done
  ui_print "! 若效果异常，请先只保留其中一个再测试"
fi

# ---------------- 3. 覆盖升级：保留两个名单 ----------------
# 名单是用户数据，升级时不能丢。其余状态交给新版重建。
if [ -d "$OLD" ]; then
  for f in lowlat.conf perapp.conf; do
    [ -f "$OLD/$f" ] && cp -f "$OLD/$f" "$MODPATH/$f" 2>/dev/null
  done
  ui_print "- 覆盖升级：已保留两个名单与低延迟参数"

  # 旧版可能还留着端口 bind mount 或模式文件；它们在新版中没有对应物。
  if [ -f "$OLD/mode" ] && [ "$(cat "$OLD/mode" 2>/dev/null)" != native ]; then
    ui_print "! 旧版处于 $(cat "$OLD/mode" 2>/dev/null) 模式，安装后请立即重启"
    ui_print "! 重启前旧版留下的端口挂载可能仍然生效"
  fi
fi

# 清掉中断事务与旧版状态标记
for stale in state/transaction state/owned state/boot.pending state/boot.failure state/base.xml state/target state/active.xml state/applied state/boot; do
  [ -e "$MODPATH/$stale" ] && rm -f "$MODPATH/$stale" 2>/dev/null
done

# ---------------- 4. 新结构初始化 ----------------
mkdir -p "$MODPATH/state" || abort "无法创建 state 目录。"
[ -f "$MODPATH/lowlat.conf" ] || printf 'enabled=1\nonly_whitelist=1\nhal_priority=20\naudio_priority=16\napp_priority=15\nwhitelist=\nrevision=initial\n' > "$MODPATH/lowlat.conf"
[ -f "$MODPATH/perapp.conf" ] || printf 'enabled=1\n' > "$MODPATH/perapp.conf"

# Leave webroot's permissions/context to the manager (KernelSU handles it specially).
set_perm_recursive "$MODPATH/bin" 0 0 0755 0644
for f in "$MODPATH"/*.sh "$MODPATH"/bin/*.sh; do
  [ -f "$f" ] && set_perm "$f" 0 0 0755
done

# ---------------- 5. 安装完成提示 ----------------
ui_print "- HyperAudioRouter 已安装"
ui_print "- 音效链路：名单内应用回落到普通轨，经过 Dolby 效果链"
ui_print "- 低延迟链路：名单内应用放音时才提升线程优先级"
ui_print "- 两份名单之外的应用保持系统默认行为"
ui_print "- 默认且唯一的工作方式是低延迟；没有全局音效模式"
ui_print "- 本模块不能与全局版共存；如曾安装全局版，请先卸载并重启"
ui_print "- KernelSU 可直接打开 WebUI；Magisk 请使用兼容的 WebUI 管理器"
