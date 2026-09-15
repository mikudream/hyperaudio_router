SKIPUNZIP=0

# ============================================================
# 音频模式切换器（hyperaudio）
# ============================================================
# 通用机型，无任何机型判断。
#
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
#   4) remove_files()：用 0 字节占位遮蔽小米音频中间层实现库与低功耗清单，
#      解除其对音频客户端 / AudioFlinger / audio policy 的接管
#
# 不含任何音效调音内容：无 ACDB 声学校准、无 Dolby DAX 调音、无 mixer 通路
# 与音量曲线改动，因此可与其他调音模块并存。
# ============================================================

set_permissions() {
  set_perm_recursive $MODPATH 0 0 0755 0644
}

replace_targets() {
  for path in $1; do
    for file in $2; do
      if [ -f "/$path/$file" ]; then
        mkdir -p "$MODPATH/$path"
        touch "$MODPATH/$path/$file"
        ui_print "- Replacing: /$path/$file"
      fi
    done
  done
}

remove_files() {
  # 用 0 字节占位遮蔽下列系统库，解除小米音频中间层对音频客户端、
  # AudioFlinger、audio policy 的接管
  replace_targets \
    "system/lib64 system/system_ext/lib64 system/vendor/lib64 odm/vendor/lib64" \
    "libaudioclientimpl.so libaudioflingerimpl.so libaudiopolicyserviceimpl.so libmiaudiopolymanager.so"

  # 遮蔽低功耗应用清单，避免音频被低功耗策略降载
  replace_targets \
    "system/etc/audio system/system_ext/etc/audio system/vendor/etc/audio odm/etc/audio" \
    "audio_lowpower_app_list.xml"
}

remove_files
set_permissions
ui_print " "
ui_print "- 音频模式切换器（通用机型）已安装"
ui_print "- 模块 ID：hyperaudio"
ui_print "- 默认工作模式：音效模式（音频走效果链，调音生效）"
ui_print "- 打开 KernelSU / APatch 管理器的本模块 WebUI 可："
ui_print "  · 一键切换 音效模式 / 低延迟模式"
ui_print "  · 配置实时优先级与生效应用白名单（低延迟模式下）"
ui_print "  · 自动检测并显示本机调音来源模块"
ui_print "- 配置文件：/data/adb/modules/hyperaudio/config.toml"
