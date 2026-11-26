#!/system/bin/sh
MODDIR=${0%/*}
# 卸载/移除模块前：把被提升的线程还原为原策略，并结束调度 daemon。
/system/bin/sh "$MODDIR/bin/ha.sh" stop
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "线程调度恢复失败；请保留错误记录并重启设备。" >&2
fi
# 清除属性只影响后续启动进程，已安装的 hook 要等目标进程退出。
/system/bin/sh "$MODDIR/bin/ha.sh" clear-properties || {
  echo "名单属性清除失败；请重启设备。" >&2
  [ "$RC" -ne 0 ] || RC=1
}
exit "$RC"
