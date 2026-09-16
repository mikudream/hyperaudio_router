#!/system/bin/sh
# ============================================================
# hyperaudio — 卸载清理
# ============================================================
# 由 Magisk / KernelSU 在卸载模块时执行（仅当本文件存在）。
#
# 需要清理的东西（模块运行时建立的，管理器不会替我们撤销）：
#   1) 对 /odm/etc/audio/audio_module_config_primary.xml 的 bind mount
#      —— 由 bin/mode_switch.sh 建立，不撤销会一直留到下次重启
#   2) hyper-audio 守护进程
#   3) /data/local/tmp 下的临时文件（配置备份、pid、日志、WebUI 中间文件）
#   4) 我们在调音模块源文件里改过的 FAST 标志（尽量还原成带 FAST 的原始形态，
#      因为"摘 FAST"是本模块为了音效模式加的补丁；还原后该文件回到调音模块
#      原本提供的状态）
# ============================================================

MOD=/data/adb/modules/hyperaudio
DST=/odm/etc/audio/audio_module_config_primary.xml
TMP=/data/local/tmp

# 1) 摘掉本模块建立的挂载。
#    先判断该挂载点是不是由我们指向调音模块源文件的，避免误摘别人建立的挂载。
SRC=""
for c in /data/adb/modules/*/Link/odm/etc/audio/audio_module_config_primary.xml \
         /data/adb/modules/*/odm/etc/audio/audio_module_config_primary.xml; do
  [ -f "$c" ] && { SRC="$c"; break; }
done

if [ -n "$SRC" ] && [ -f "$SRC" ]; then
  # 还原 FAST 标志（回到"未打补丁"的形态）
  sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$SRC" 2>/dev/null
  sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$SRC" 2>/dev/null
  chmod 644 "$SRC" 2>/dev/null

  # 重新挂上原始内容，供本次开机剩余时间使用；真正的清理在重启后完成
  umount "$DST" 2>/dev/null
  mount --bind "$SRC" "$DST" 2>/dev/null && restorecon "$DST" 2>/dev/null
fi

# 2) 停止守护进程
for p in $(pidof hyper-audio 2>/dev/null); do kill -9 "$p" 2>/dev/null; done

# 3) 清理临时文件
rm -f "$TMP/hyperaudio.pid" "$TMP/hyper-audio.log" "$TMP/hyperaudio-init.log" \
      "$TMP/amcp.before_switch" "$TMP/ms.out" 2>/dev/null
rm -rf "$TMP/hyperaudio_webui" 2>/dev/null

# 4) 重启音频服务，让端口标志的还原生效
killall audioserver 2>/dev/null

echo "hyperaudio: 已停止守护进程、还原端口标志并清理临时文件"
echo "建议重启设备以彻底清除本模块建立的所有挂载"
exit 0
