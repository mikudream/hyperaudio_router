#!/system/bin/sh
MODDIR=${0%/*}
# 卸载/移除模块前：把被提升的线程还原为原策略，并结束调度 daemon。
/system/bin/sh "$MODDIR/bin/ha.sh" stop
RC=$?
echo "已请求还原线程调度。若上方报告恢复失败，请保留错误记录。"
exit "$RC"
