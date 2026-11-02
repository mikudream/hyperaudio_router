#!/system/bin/sh
MODDIR=${0%/*}
/system/bin/sh "$MODDIR/bin/ha.sh" recover
RC=$?
echo "已请求恢复原生及撤销调度。若上方报告恢复失败，请保留错误记录。"
exit "$RC"
