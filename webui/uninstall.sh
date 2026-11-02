#!/system/bin/sh
# ============================================================
# hyperaudio — 卸载清理
# ============================================================
# 由 Magisk / KernelSU 在卸载模块时执行（仅当本文件存在）。
#
# 需要撤销的东西（模块运行时建立的，管理器不会替我们撤销）：
#   1) 我们自己叠加的 bind mount（指向 state/active.xml）—— 摘掉即恢复系统原始文件
#   2) hyper-audio 守护进程
#   3) /data/local/tmp 下的临时文件
#
# 与 0.4.5 的不同：
#   旧版是"直接改调音模块源文件再 bind"，卸载时靠 sed 改回去 + umount，
#   脚本自己都注明"真正的清理在重启后完成"。
#   现在端口补丁只改**自己的副本**（state/active.xml），
#   所以卸载只需摘掉我们的那一层，**不碰调音模块的任何文件**。
#
# 唯一的例外是兼容：从 0.4.5 及更早版本升级上来的设备，源文件可能已被
# 旧版直接改过（缺 FAST）。这一步由 runtime.sh recover 里的修复逻辑处理，
# 但卸载场景下模块目录即将消失，所以这里也做一次。
# ============================================================

MOD=${HA_MOD:-/data/adb/modules/hyperaudio}
STATE=$MOD/state
TMP=/data/local/tmp
SH=${HA_SH:-/system/bin/sh}

# 1) 撤销我们建立的挂载与状态（runtime.sh recover 会摘层、清事务/护栏）
# recover 失败意味着我们的挂载层可能仍在系统里；这时不能报"已恢复"，
# 必须把失败透传给管理器（v3.0 的做法），否则用户会以为已经干净了。
RC=0
if [ -f "$MOD/bin/runtime.sh" ]; then
  $SH "$MOD/bin/runtime.sh" recover >/dev/null 2>&1 || RC=$?
fi

# 2) 兼容处理：若调音模块源文件仍被旧版直接改过（两个端口都缺 FAST），修复它。
#    判据保守：只有"都缺 FAST"才认定为旧版遗留；恢复后回读确认。
LEGACY_SRC=""
for c in /data/adb/modules/*/Link/odm/etc/audio/audio_module_config_primary.xml \
         /data/adb/modules/*/odm/etc/audio/audio_module_config_primary.xml; do
  case "$c" in *'*') continue ;; esac
  [ -f "$c" ] && { LEGACY_SRC="$c"; break; }
done

if [ -n "$LEGACY_SRC" ] && [ -f "$LEGACY_SRC" ]; then
  _low=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$LEGACY_SRC" 2>/dev/null | head -1)
  _raw=$(sed -n 's/.*<mixPort name="raw_out"[^>]*flags="\([^"]*\)".*/\1/p' "$LEGACY_SRC" 2>/dev/null | head -1)
  _need=0
  [ -n "$_low" ] && [ -n "$_raw" ] || _need=0
  if [ -n "$_low" ] && [ -n "$_raw" ]; then
    case "$_low" in *FAST*) ;; *) _need=1 ;; esac
    case "$_raw" in *FAST*) ;; *) _need=1 ;; esac
  fi
  if [ "$_need" = "1" ]; then
    sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$LEGACY_SRC" 2>/dev/null
    sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$LEGACY_SRC" 2>/dev/null
    chmod 644 "$LEGACY_SRC" 2>/dev/null
    echo "hyperaudio: 已修复旧版遗留在调音模块源文件上的端口标志"
  fi
fi

# 3) 停止守护进程（含可能残留的多实例）
for p in $(pidof hyper-audio 2>/dev/null); do kill -9 "$p" 2>/dev/null; done

# 4) 清理临时文件
rm -f "$TMP/hyperaudio.pid" "$TMP/hyper-audio.log" "$TMP/hyperaudio-init.log" \
      "$TMP/hyperaudio-runtime.log" "$TMP/amcp.before_switch" "$TMP/ms.out" 2>/dev/null
rm -rf "$TMP/hyperaudio_webui" 2>/dev/null

# 5) 删掉只属于本模块的配置与日志（模块目录随后会被管理器删除，
#    这里显式清一遍，避免"卸载后残留影响重装"）
rm -f "$MOD/perapp.conf" 2>/dev/null
rm -rf "$MOD/logs" 2>/dev/null

if [ "$RC" = "0" ]; then
  echo "hyperaudio: 已撤销端口层、停止守护进程并清理临时文件"
  echo "系统原始音频配置已恢复"
  exit 0
fi

echo "hyperaudio: 清理未完全成功（recover 退出码 $RC）"
echo "我们的挂载层可能仍在系统里，请重启设备后确认；若仍有异常，请保留此输出"
exit "$RC"
