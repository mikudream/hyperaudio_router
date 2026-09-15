#!/system/bin/sh
# hyper-audio 守护进程启动器
# 独立成文件并由 setsid 调用，使其新开会话、完全脱离父脚本，
# 避免父脚本退出（或其中执行 killall 等操作）时把守护进程一起带走。
MOD=/data/adb/modules/hyperaudio
PIDFILE=/data/local/tmp/hyperaudio.pid
LOG=/data/local/tmp/hyper-audio.log

cd "$MOD" || exit 1
[ -x ./hyper-audio ] || exit 1

# 若已在运行则退出
if [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then
  pidof hyper-audio 2>/dev/null | awk '{print $1}' > "$PIDFILE"
  exit 0
fi

./hyper-audio >> "$LOG" 2>&1 &
sleep 1
P=$(pidof hyper-audio 2>/dev/null | awk '{print $1}')
if [ -n "$P" ]; then
  printf '%s\n' "$P" > "$PIDFILE"
  echo "started pid=$P"
else
  echo "failed"
fi
