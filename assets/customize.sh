SKIPUNZIP=0

# ============================================================
# 音频模式切换器（hyperaudio）
# ============================================================
# 作用：
#   1) 注入低延迟音频属性（system.prop）：AAudio MMAP 独占通路、
#      HAL 缓冲周期压缩、蓝牙高清编解码与硬件直通、位深与音效开关等
#   2) 由 service.sh 按 mode 文件决定行为：
#        音效模式（默认）—— 摘掉音频端口的 FAST 标志，使所有应用音频落入
#                          效果链，音效 / 按应用调音得以全局生效
#        低延迟模式      —— 恢复 FAST 标志并启动 hyper-audio 守护进程，
#                          按 config.toml 的白名单与优先级把音频线程提升为
#                          SCHED_FIFO 实时优先级，降低延迟抖动
#   3) 替换 libaaudio_internal*.so，启用 HyperOS 的 AAudio MMAP 通路实现
#
# 注意：本模块【不再】对任何系统音频库做遮蔽。早期版本会用 0 字节占位遮蔽
# libaudio{client,flinger,policyservice}impl.so，实测这只会让音频实现层失效：
# 音效模式下效果链通路整个哑掉（调音全无、部分音频无声），低延迟模式虽仍有声
# 但调音同样失效。详见下方 set_permissions 上方的说明。
#
# 机型适配：本模块自身不含机型判断；但音效模式依赖外部调音模块提供
# audio_module_config_primary.xml（见 bin/runtime.sh 的 detect_src）。
#
# 不含任何音效调音内容：无 ACDB 声学校准、无 Dolby DAX 调音、无 mixer 通路
# 与音量曲线改动，因此可与其他调音模块并存。
# ============================================================

set_permissions() {
  # 先统一：目录 0755、文件 0644
  set_perm_recursive $MODPATH 0 0 0755 0644

  # 再补回可执行位。
  # 安装器的 set_perm_recursive 会把文件一律设为 0644，连 zip 里带执行位的
  # 脚本也会被抹掉；若只靠 service.sh 开机时 chmod，则 WebUI 的 helper.sh
  # 会因 126 Permission denied 而**完全没有输出**（WebUI 报"helper 无输出"）。
  # 用 [ -f ] 保护，避免文件缺失时 chmod 报错中断安装。
  for f in $MODPATH/hyper-audio $MODPATH/action.sh $MODPATH/uninstall.sh \
           $MODPATH/webui/helper.sh \
           $MODPATH/bin/runtime.sh $MODPATH/bin/audio_ready.sh \
           $MODPATH/bin/start_daemon.sh \
           $MODPATH/bin/detect_tuning.sh; do
    [ -f "$f" ] && chmod 0755 "$f"
  done

  # 这两个 awk 脚本由 awk 读取（不需要执行位），但显式设一遍 0644，
  # 避免不同管理器对 zip 内权限的处理差异。
  for f in $MODPATH/bin/patch_ports.awk $MODPATH/bin/check_audio_ready.awk; do
    [ -f "$f" ] && chmod 0644 "$f"
  done
}

# ── 不再遮蔽任何系统音频库（重要）────────────────────────────
# 这里原本会往模块里写 0 字节占位来遮蔽以下文件：
#   system/system_ext/lib64/libaudioclientimpl.so
#   system/system_ext/lib64/libaudioflingerimpl.so
#   system/system_ext/lib64/libaudiopolicyserviceimpl.so
#   odm/vendor/lib64/libmiaudiopolymanager.so
#   .../audio_lowpower_app_list.xml
#
# 实测结论：挖空这些 *impl.so 只会
# 让音频实现层失效，对"阻止应用拿到 ULL 通路"没有任何帮助，反而造成严重后果：
#   · 音效模式：effect chain 所在的混音通路整个哑掉 —— 调音全无，且部分音频无声
#   · 低延迟模式：fast track 走另一条通路，仍有声，但调音完全失效
# 也就是说，遮蔽它们既达不到低延迟目的，又把调音一起废掉了，故彻底移除。
set_permissions

# ── 原地清理旧版（<=0.4.5）留下的东西 ─────────────────────────
# 旧版是"直接改调音模块源文件再 bind"的，两者都会残留到重启：
#   · 内核里的 bind mount 不会因为覆盖安装而消失，而它指向的正是被改过的源文件
#   · 源文件本身的 FAST 标志已被旧版 sed 摘掉
# 这里就地撤掉：先修好源文件，再摘掉旧版那一层，使 /odm 立刻回到原始配置。
# 判据保守：只在"两个端口都缺 FAST"时认定为旧版遗留。
_cleanup_old_overlay() {
  _mounted=""
  for _c in /data/adb/modules/*/Link/odm/etc/audio/audio_module_config_primary.xml \
            /data/adb/modules/*/odm/etc/audio/audio_module_config_primary.xml; do
    case "$_c" in *'*') continue ;; esac
    [ -f "$_c" ] || continue
    _low=$(sed -n 's/.*<mixPort name="low_latency_out"[^>]*flags="\([^"]*\)".*/\1/p' "$_c" 2>/dev/null | head -1)
    _raw=$(sed -n 's/.*<mixPort name="raw_out"[^>]*flags="\([^"]*\)".*/\1/p' "$_c" 2>/dev/null | head -1)
    [ -n "$_low" ] && [ -n "$_raw" ] || continue
    _need=0
    case "$_low" in *FAST*) ;; *) _need=1 ;; esac
    case "$_raw" in *FAST*) ;; *) _need=1 ;; esac
    if [ "$_need" = "1" ]; then
      sed -i 's|\(<mixPort name="low_latency_out" role="source" flags="\)PRIMARY">|\1FAST PRIMARY">|' "$_c" 2>/dev/null
      sed -i 's|\(<mixPort name="raw_out" role="source" flags="\)RAW">|\1FAST RAW">|' "$_c" 2>/dev/null
      chmod 644 "$_c" 2>/dev/null
      ui_print "- 已修复旧版遗留在调音模块源文件上的端口标志"
    fi
    # 找到对应的生效路径并摘掉旧版的层
    # /data/adb/modules/<mod>/Link/odm/etc/... -> /odm/etc/...
    _r=${_c#/data/adb/modules/}
    _r=${_r#*/}
    _r=${_r#Link/}
    case "$_r" in
      odm/*|vendor/*|system/*) _dst="/$_r" ;;
      *) continue ;;
    esac
    if [ -f "$_dst" ]; then
      # 只有能**明确证明**这一层是旧版建立的才摘：目标是挂载点，且其内容与
      # 调音模块源文件不同（= 旧版改过）。任何一环拿不到证据就保持不动 ——
      # 宁可留到重启，也不误摘调音模块自己建立的层。
      _is_mnt=0
      if [ -r /proc/self/mountinfo ] && awk -v t="$_dst" '$5==t{found=1} END{exit !found}' /proc/self/mountinfo 2>/dev/null; then
        _is_mnt=1
      fi
      if [ "$_is_mnt" = "1" ] && cmp -s "$_dst" "$_c" 2>/dev/null; then
        _is_mnt=0   # 内容与源一致 => 是调音模块自己的层，不动
      fi
      if [ "$_is_mnt" = "1" ]; then
        umount "$_dst" 2>/dev/null && ui_print "- 已撤销旧版建立的音频配置层（$_dst）"
      fi
    fi
  done
}
_cleanup_old_overlay

ui_print " "
ui_print "- 音频模式切换器（通用机型）已安装"
ui_print "- 模块 ID：hyperaudio"
ui_print "- 默认工作模式：音效模式（音频走效果链，调音生效）"
ui_print "- 打开 KernelSU / APatch 管理器的本模块 WebUI 可："
ui_print "  · 一键切换 音效模式 / 低延迟模式"
ui_print "  · 配置实时优先级与生效应用白名单（低延迟模式下）"
ui_print "  · 自动检测并显示本机调音来源模块"
ui_print "- 配置文件：/data/adb/modules/hyperaudio/config.toml"
