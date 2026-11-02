SKIPUNZIP=0
[ "$BOOTMODE" = true ] || abort "请在 Magisk / KernelSU 管理器内安装，不支持 recovery。"
OLD=/data/adb/modules/hyperaudio
# 旧版（本模块的历史版本）使用 state/*.xml 与 config.toml，新版用 mode/state 结构。
# 覆盖升级时只保留能对得上的配置，其余交给新版重建，避免因模式不同而中止安装。
if [ -d "$OLD" ]; then
  for f in boot.conf sound.conf lowlat.conf; do
    [ -f "$OLD/$f" ] && cp -f "$OLD/$f" "$MODPATH/$f" 2>/dev/null
  done
  ui_print "- 覆盖升级：已保留可复用的配置文件"
fi
# 新结构：mode 默认 native，state 目录供事务与回退使用
mkdir -p "$MODPATH/state" || abort "无法创建 state 目录。"
[ -f "$MODPATH/mode" ] || printf 'native\n' > "$MODPATH/mode"
chmod 0644 "$MODPATH/mode" 2>/dev/null
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
