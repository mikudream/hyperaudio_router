SKIPUNZIP=0
[ "$BOOTMODE" = true ] || abort "请在 Magisk / KernelSU 管理器内安装，不支持 recovery。"
case "$API" in 36|37) ;; *) abort "本版仅面向 Android 16/17（API 36/37）。" ;; esac
[ "$ARCH" = arm64 ] || abort "本版仅面向 arm64。"
DEVICE=$(getprop ro.product.device)
[ "$DEVICE" = myron ] || abort "本版仅面向 K90 Pro Max（myron），当前为 $DEVICE。"
if [ -d /data/adb/modules/hyperaudio ] || [ -d /data/adb/modules_update/hyperaudio ]; then
  abort "请先将旧 hyperaudio 切回低延迟模式、卸载并重启，再安装本版。禁用旧版不足以恢复它改过的文件。"
fi
OLD=/data/adb/modules/hyperaudio_compat
if [ -d "$OLD" ]; then
  OLD_MODE=$(cat "$OLD/mode" 2>/dev/null)
  OLD_APPLIED=$(cat "$OLD/state/applied" 2>/dev/null)
  case "$OLD_APPLIED" in native|'') ;; *) abort "当前已应用其他音频模式；请先回到原生再覆盖升级。" ;; esac
  if [ "$OLD_MODE" != native ] || [ -f "$OLD/state/owned" ] || [ -f "$OLD/state/transaction" ]; then
    abort "请先在已安装版本切回原生模式，确认游戏有声后再覆盖升级；仍失败则先卸载并重启。"
  fi
  # Snapshot preferences BEFORE the old recovery command disables its scheduler
  # (and, on new versions, resets its own startup preference).
  if [ -f "$OLD/boot.conf" ]; then
    cp "$OLD/boot.conf" "$MODPATH/boot.conf" || abort "无法保留开机模式设置。"
    ( MODDIR=$MODPATH; . "$MODPATH/bin/boot.sh"; boot_read_config ) || abort "开机配置无效，请先重新保存开机设置再升级。"
  fi
  if [ -f "$OLD/sound.conf" ]; then
    cp "$OLD/sound.conf" "$MODPATH/sound.conf" || abort "无法保留音效通路配置。"
    (
      MODDIR=$MODPATH
      . "$MODPATH/bin/sound.sh"
      sound_read_config || exit 1
      # Validate as data, then migrate legacy FAST to both independent port settings.
      printf 'custom=%s\nmmap=%s\nfast=%s\nfast_raw=%s\nraw=%s\n' \
        "$SOUND_CUSTOM" "$SOUND_MMAP" "$SOUND_FAST" "$SOUND_FAST_RAW" "$SOUND_RAW" > "$MODPATH/sound.conf.new" || exit 1
      chmod 0600 "$MODPATH/sound.conf.new" && mv -f "$MODPATH/sound.conf.new" "$MODPATH/sound.conf"
    ) || abort "音效配置无效或无法迁移，请先恢复默认配置再升级。"
  fi
  if [ -f "$OLD/state/boot.failure" ]; then
    mkdir -p "$MODPATH/state" || abort "无法保留启动回退记录。"
    cp "$OLD/state/boot.failure" "$MODPATH/state/boot.failure" || abort "无法保留启动回退记录。"
    set_perm "$MODPATH/state" 0 0 0700
    set_perm "$MODPATH/state/boot.failure" 0 0 0600
  fi
  if [ -f "$OLD/lowlat.conf" ]; then
    cp "$OLD/lowlat.conf" "$MODPATH/lowlat.conf" || abort "无法保留低延迟参数。"
    /system/bin/sh "$OLD/bin/ha.sh" recover || abort "请先恢复原生并关闭低延迟后再升级。"
  fi
  ui_print "- 覆盖升级：已撤销旧版调度，保留开机选择、音效通路及低延迟配置"
fi
# Leave webroot's permissions/context to the manager (KernelSU handles it specially).
set_perm_recursive "$MODPATH/bin" 0 0 0755 0644
for f in "$MODPATH"/*.sh "$MODPATH"/bin/*.sh; do
  [ -f "$f" ] && set_perm "$f" 0 0 0755
done
ui_print "- HyperAudio Switch 3.0 正式版"
ui_print "- 支持 Miuix / Material 3 界面与可选悬浮底栏"
ui_print "- 支持原生与音效模式，可调整低延迟和音频设置"
ui_print "- 可选择开机模式，已保存的设置会保留"
ui_print "- 启用模块后，日常切换无需重启手机；切换后请重新打开游戏"
ui_print "- 部分游戏在音效模式下可能出现电流声、破音或无声"
ui_print "- 安装完成后，请按管理器提示启用模块"
ui_print "- KernelSU 可直接打开 WebUI；Magisk 请使用兼容的 WebUI 管理器"
