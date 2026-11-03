#!/bin/sh
# ============================================================
# 主机侧测试入口（不随模块包分发）
# ============================================================
# 用法: sh tests/run.sh
#
# 这些测试在开发机上运行，用来验证纯逻辑组件：
#   · patch_ports.awk   有界 XML 编辑器：正常改写 + 异常必须 fail-closed
#   · helper.sh save    配置严格校验：非法输入必须整体拒绝且不落盘
#
# 它们**不能**替代真机验证：端口挂载、事务回滚、开机护栏都依赖
# root / busybox / init 挂载命名空间，只能在设备上验。
#
# 依赖：POSIX sh + awk（gawk / busybox awk 均可）。手机上不需要跑这些。
# ============================================================
HERE=$(dirname "$0")
rc=0

echo "############################################################"
echo "# 1. patch_ports.awk"
echo "############################################################"
if sh "$HERE/test_patch_ports.sh" "$HERE/../webui/patch_ports.awk"; then
  echo "  -> 通过"
else
  echo "  -> 失败"; rc=1
fi

echo ""
echo "############################################################"
echo "# 2. helper.sh save 的严格校验"
echo "############################################################"
if sh "$HERE/test_save_validation.sh"; then
  echo "  -> 通过"
else
  echo "  -> 失败"; rc=1
fi

echo ""
echo "############################################################"
echo "# 3. runtime.sh 状态机（依赖注入）"
echo "############################################################"
if sh "$HERE/test_runtime_state_machine.sh"; then
  echo "  -> 通过"
else
  echo "  -> 失败"; rc=1
fi

echo ""
echo "############################################################"
echo "# 4. 音频就绪校验（report_flags / dumpsys 解析）"
echo "############################################################"
if sh "$HERE/test_audio_ready.sh"; then
  echo "  -> 通过"
else
  echo "  -> 失败"; rc=1
fi

echo ""
echo "############################################################"
echo "# 5. 配置文件不因反复保存而增长"
echo "############################################################"
# ---------------- 6. 诊断导出（只读性 / 结构 / 落盘） ----------------
echo ""
echo "############ 6. 诊断导出（只读、结构完整、可落盘）############"
if sh "$HERE/test_diagnose.sh"; then
echo "  -> 通过"
else
echo "  -> 失败"; rc=1
fi
if sh "$HERE/test_save_no_accumulation.sh"; then
  echo "  -> 通过"
else
  echo "  -> 失败"; rc=1
fi

echo ""
# ---------------- 8. 动作按钮 / 卸载 ----------------
echo ""
echo "############ 8. 动作按钮与卸载（就绪结论、失败原因、退出码）############"
if sh "$HERE/test_action_uninstall.sh"; then
echo "  -> 通过"
else
echo "  -> 失败"; rc=1
fi
# ---------------- 9. system.prop 守护 ----------------
echo ""
echo "############ 9. system.prop（去重、关键项、MMAP 说明）############"
if sh "$HERE/test_system_prop.sh"; then
echo "  -> 通过"
else
echo "  -> 失败"; rc=1
fi
# ---------------- 10. WebUI 渲染（无浏览器）----------------
if command -v node >/dev/null 2>&1; then
  echo ""
  echo "############ 10. WebUI 静态一致性（DOM 引用）############"
  if node "$HERE/test_webui_dom.js"; then
  echo "  -> 通过"
  else
  echo "  -> 失败"; rc=1
  fi
fi
# ---------------- 11. 应用版后端（router.sh）----------------
echo ""
echo "############ 11. 应用版后端：两个名单的增删与校验 ############"
if sh "$HERE/test_router_sh.sh"; then
echo "  -> 通过"
else
echo "  -> 失败"; rc=1
fi
if [ "$rc" = "0" ]; then
  echo "全部主机侧测试通过"
else
  echo "有测试失败"
fi
exit "$rc"
