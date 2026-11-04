#!/bin/sh
# ============================================================
# 主机侧测试入口（不随模块包分发）
# ============================================================
# 用法: sh tests/run.sh
#
# 这些测试在开发机上运行，用来验证纯逻辑组件：
#   · router.sh      两个名单的读写、包名校验、互斥迁移
#   · lowlat.sh      白名单配置解析与保存（不测真实 chrt）
#   · ha.sh          只读动作能否在桩环境里跑完（冒烟）
#   · system.prop    去重与关键项守护
#   · WebUI          静态 DOM 一致性（每个 $('id') 都能解析）
#
# 它们**不能**替代真机验证：线程提升、zygisk 注入、Dolby 是否生效
# 都依赖 root / 目标进程 / 音频 HAL，只能在设备上验证。
#
# 依赖：POSIX sh + awk（gawk / busybox awk 均可）；DOM 检查需要 node。
# ============================================================
HERE=$(dirname "$0")
rc=0

section() {
  echo ""
  echo "############################################################"
  echo "# $1"
  echo "############################################################"
}

run_test() {
  if sh "$HERE/$1"; then
    echo "  -> 通过"
  else
    echo "  -> 失败"; rc=1
  fi
}

section "1. router.sh：两个名单的读写、校验与互斥迁移"
run_test test_router_sh.sh

section "2. lowlat.sh：白名单配置解析与保存"
run_test test_lowlat_config.sh

section "3. customize.sh：覆盖安装与冲突提示"
run_test test_install_conflict.sh

section "4. ha.sh：桩环境冒烟"
run_test test_ha_smoke.sh

section "5. system.prop：去重与关键项"
run_test test_system_prop.sh

section "5.1 webui.sh argument patterns"
run_test test_webui_patterns.sh

if command -v node >/dev/null 2>&1; then
  section "6. WebUI 静态一致性（DOM 引用）"
  if node "$HERE/test_webui_dom.js"; then
    echo "  -> 通过"
  else
    echo "  -> 失败"; rc=1
  fi
else
  echo ""
  echo "# 跳过 WebUI DOM 检查（未找到 node）"
fi

echo ""
if [ "$rc" = 0 ]; then
  echo "全部主机侧测试通过"
else
  echo "有测试失败"
fi
exit "$rc"
