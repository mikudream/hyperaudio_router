#!/system/bin/sh
# hyper-audio 守护进程启动器
# 独立成文件并由 setsid 调用，使其新开会话、完全脱离父脚本，
# 避免父脚本退出（或其中执行 killall 等操作）时把守护进程一起带走。
#
# 退出码约定：0 = 已在运行或启动成功；1 = 失败。
# 调用方必须检查该退出码，不要把"没起来"当成功。
MOD=/data/adb/modules/hyperaudio
PIDFILE=/data/local/tmp/hyperaudio.pid
LOG=/data/local/tmp/hyper-audio.log

cd "$MOD" || exit 1

# 不能用 [ -x ] 判定：安装时 set_perm_recursive 会把文件统一设为 0644，
# 执行位可能不存在（本项目已因此出过 helper.sh「126 无输出」的事故）。
# 用 -f 判存在，再显式 chmod 后尝试启动。
[ -f ./hyper-audio ] || { echo "missing hyper-audio"; exit 1; }

# 统计实例。注意：不能写成"只要有一个在运行就直接退出" —— 那样遇到多个游离
# 实例（绕过本启动器直接 setsid 起来的，或上次启动残留）时会把它们全部放过，
# 多个实例会重复扫同一批音频线程、重复写同一日志。实测过这种情形。
COUNT=0
FIRST=""
for _p in $(pidof hyper-audio 2>/dev/null); do
  # 用 /proc/<pid>/comm 复核，避免 pidof 的名字匹配到别的进程
  _c=$(cat /proc/$_p/comm 2>/dev/null)
  case "$_c" in
    *hyper-audio*)
      COUNT=$((COUNT + 1))
      [ -n "$FIRST" ] || FIRST="$_p"
      ;;
  esac
done

if [ "$COUNT" -eq 1 ] && [ -n "$FIRST" ]; then
  printf '%s\n' "$FIRST" > "$PIDFILE"
  echo "already running pid=$FIRST"
  exit 0
fi

if [ "$COUNT" -gt 1 ]; then
  # 多实例：全部清掉后重新起一个，收敛到单实例
  for _p in $(pidof hyper-audio 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done
  sleep 1
  echo "cleaned up $COUNT stale instances"
fi

chmod +x ./hyper-audio 2>/dev/null
./hyper-audio >> "$LOG" 2>&1 &
sleep 1

P=$(pidof hyper-audio 2>/dev/null | awk '{print $1}')
if [ -n "$P" ]; then
  printf '%s\n' "$P" > "$PIDFILE"
  # 复核只起来了一个
  N=$(pidof hyper-audio 2>/dev/null | wc -w | tr -d ' ')
  echo "started pid=$P (instances=$N)"
  exit 0
else
  echo "failed (hyper-audio did not stay running)"
  exit 1
fi
