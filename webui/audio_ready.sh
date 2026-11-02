#!/system/bin/sh
# ============================================================
# 音频就绪校验
# ============================================================
# 解决的问题：切换模式后我们只证明了"磁盘上的配置文件内容对"，
# 没有证明 **audioserver 真的加载了它**。两者之间有一个真实的窗口 ——
# 服务重启后要先读策略、建主输出、填充 HAL 缓冲，这段时间里配置可能还没生效。
# 本文件在重启音频服务后逐次探测，只有"同一 PID + 同一观测签名连续 3 次"
# 才算通过，并拿 dumpsys 里实际加载的端口 flags 与我们写入的期望值比对。
#
# 移植自 HyperAudio Switch v3.0 的 bin/audio_ready.sh
# （作者 月见里幽瞳 / 海希安的城主），见 CREDITS.md「借鉴与参考」。
# 相对原版的改动：
#   · 模式名沿用本模块：sound / fast（原版是 native / compat / sound）
#   · 重启方式沿用本模块的 killall audioserver（原版用 setprop ctl.restart）
#   · **区分"证明错了"与"无法验证"**：只有"加载的 flags 与我们写的确实不符"
#     或"音频服务根本没起来"才算失败；dumpsys 读不到、格式不认只算"未验证"，
#     不清空用户的模式选择，也不触发回滚。原版一律当失败。
#   · 期望值取自本模块自己维护的 base.xml / 调音模块源文件
#
# 明确边界：加载了配置不等于能出声，也不证明 Dolby 正在处理。只是"框架读到了"。
# ============================================================

AR_DIR=$STATE/audio-ready
CHECKER=$MOD/bin/check_audio_ready.awk

audio_ready_init() { mkdir -p "$AR_DIR" 2>/dev/null; }
audio_now() { awk '{print int($1)}' /proc/uptime 2>/dev/null; }
audio_ready_reason() { head -1 "$AR_DIR/reason.txt" 2>/dev/null | tr -d ' \r\n'; }

# 哪些原因算"确实坏了"（→ 回滚）；其余一律只算"无法验证"
#   loaded_*_flags_mismatch : dumpsys 读得到 flags，且与预期不符 —— 证伪
#   audioserver_not_running  : 音频服务没起来 —— 确实是故障
audio_ready_is_fatal() {
  case "$1" in
    loaded_low_latency_flags_mismatch|loaded_raw_flags_mismatch) return 0 ;;
    audioserver_not_running) return 0 ;;
    *) return 1 ;;
  esac
}

# 计算"本次模式下应当加载的端口 flags 位掩码"，写入 $AR_DIR/expected.txt。
#   sound：base.xml 摘掉对应标志后的结果
#   fast ：原始配置（不摘任何标志）
# 拿不到基线/源文件时返回 0 但不设期望值（表示"只校验框架存活，不校验 flags"）。
audio_expected_flags() {
  _m=$1
  AUDIO_EXPECT_LOW=""; AUDIO_EXPECT_RAW=""
  audio_ready_init || return 1
  : > "$AR_DIR/expected.txt" 2>/dev/null || return 1
  [ -f "$CHECKER" ] || return 0
  [ -f "$PATCHER" ] || return 0

  case "$_m" in
    sound)
      [ -s "$STATE/base.xml" ] || return 0
      # 与 runtime.sh 的 prepare_patch 参数必须一致：只摘 FAST，保留 RAW
      awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=0 -v report_flags=1 \
        -f "$PATCHER" "$STATE/base.xml" > "$AR_DIR/expected.txt" 2> "$AR_DIR/reason.txt" || return 1
      ;;
    fast)
      [ -n "${SRC:-}" ] && [ -f "$SRC" ] || return 0
      awk -v remove_fast_low=0 -v remove_fast_raw=0 -v remove_raw=0 -v report_flags=1 \
        -f "$PATCHER" "$SRC" > "$AR_DIR/expected.txt" 2> "$AR_DIR/reason.txt" || return 1
      ;;
    *) return 0 ;;
  esac

  AUDIO_EXPECT_LOW=$(sed -n 's/^low_latency_out=//p' "$AR_DIR/expected.txt" 2>/dev/null)
  AUDIO_EXPECT_RAW=$(sed -n 's/^raw_out=//p' "$AR_DIR/expected.txt" 2>/dev/null)
  return 0
}

# 单次探测：全部只读，不重启任何服务、不制造播放流
audio_ready_probe() {
  _pid=$1
  [ -n "$_pid" ] || return 1
  audio_ready_init || return 1

  [ "$(getprop init.svc.audioserver 2>/dev/null)" = running ] || {
    echo audioserver_not_running > "$AR_DIR/reason.txt"; return 1
  }
  if ! dumpsys -t 2 media.audio_policy > "$AR_DIR/policy.txt" 2>&1; then
    echo audio_policy_unavailable > "$AR_DIR/reason.txt"; return 1
  fi
  if ! dumpsys -t 2 media.audio_flinger > "$AR_DIR/flinger.txt" 2>&1; then
    echo audio_flinger_unavailable > "$AR_DIR/reason.txt"; return 1
  fi
  # 探测期间 PID 变了说明服务又在重启，本次观测不算数
  [ "$(pidof audioserver 2>/dev/null)" = "$_pid" ] || {
    echo audioserver_changed_during_probe > "$AR_DIR/reason.txt"; return 1
  }
  [ -f "$CHECKER" ] || { echo checker_missing > "$AR_DIR/reason.txt"; return 1; }

  awk -v expected_low="$AUDIO_EXPECT_LOW" -v expected_raw="$AUDIO_EXPECT_RAW" \
    -f "$CHECKER" "$AR_DIR/policy.txt" "$AR_DIR/flinger.txt" \
    > "$AR_DIR/observed.txt" 2> "$AR_DIR/reason.txt"
}

# 等待音频框架真正就绪。
#   $1 = 模式；$2 = 重启前的 audioserver PID
# 通过条件：PID 已更换、策略/混音器可读、主输出与 HAL 缓冲就绪、
#           加载的端口 flags 与期望一致、且同一 PID+签名连续 3 次。
# 上限：30 秒 / 20 次（双保险，避免慢机型上无限等）。
audio_wait_ready() {
  _mode=$1; _old=$2
  audio_ready_init || { err audio_ready_state_unavailable; return 1; }
  rm -f "$AR_DIR/pid" "$AR_DIR/boot" "$AR_DIR/policy.txt" "$AR_DIR/flinger.txt" \
        "$AR_DIR/observed.txt" "$AR_DIR/reason.txt" 2>/dev/null
  echo waiting > "$AR_DIR/result.txt"
  printf '%s\n' "$_mode" > "$AR_DIR/mode.txt" 2>/dev/null

  if ! audio_expected_flags "$_mode"; then
    # 期望值算不出来：只校验框架存活，不校验 flags（会记进 reason）
    AUDIO_EXPECT_LOW=""; AUDIO_EXPECT_RAW=""
  fi

  _start=$(audio_now); [ -n "$_start" ] || _start=0
  _attempts=0; _last_pid=""; _last_sig=""; _stable=0; _reason=""

  while [ "$_attempts" -lt 20 ]; do
    _now=$(audio_now); [ -n "$_now" ] || _now=$_start
    if [ $((_now - _start)) -ge 30 ]; then _reason=probe_timeout; break; fi
    _attempts=$((_attempts + 1))

    _pid=$(pidof audioserver 2>/dev/null)
    if [ -n "$_pid" ] && [ "$_pid" != "$_old" ] && audio_ready_probe "$_pid"; then
      _sig=$(cat "$AR_DIR/observed.txt" 2>/dev/null)
      if [ "$_pid" = "$_last_pid" ] && [ "$_sig" = "$_last_sig" ]; then
        _stable=$((_stable + 1))
      else
        _stable=1
      fi
      _last_pid=$_pid; _last_sig=$_sig
      if [ "$_stable" -ge 3 ]; then
        printf '%s\n' "$_pid" > "$AR_DIR/pid" 2>/dev/null
        printf '%s\n' "${BOOT_ID:-unknown}" > "$AR_DIR/boot" 2>/dev/null
        echo passed > "$AR_DIR/result.txt"
        rm -f "$AR_DIR/reason.txt" 2>/dev/null
        log "audio ready: pid=$_pid probes=$_attempts flags_checked=$([ -n "$AUDIO_EXPECT_LOW" ] && echo yes || echo no)"
        return 0
      fi
    else
      _stable=0; _last_pid=""; _last_sig=""
      if [ -z "$_pid" ]; then
        _reason=audioserver_not_running
      elif [ "$_pid" = "$_old" ]; then
        _reason=audioserver_pid_not_replaced
      else
        _reason=$(audio_ready_reason)
      fi
    fi
    sleep 1
  done

  [ -n "$_reason" ] || _reason=probe_timeout
  printf '%s\n' "$_reason" > "$AR_DIR/reason.txt" 2>/dev/null
  if [ "$_reason" = probe_timeout ]; then echo timeout > "$AR_DIR/result.txt"
  else echo failed > "$AR_DIR/result.txt"; fi
  log "audio readiness not confirmed; mode=$_mode reason=$_reason probes=$_attempts"
  return 1
}

# 供 status / WebUI 读取。只有 boot 与当前 audioserver PID 都对得上才认上次结果。
audio_ready_state() {
  _r=$(cat "$AR_DIR/result.txt" 2>/dev/null | tr -d ' \r\n')
  case "$_r" in
    passed)
      if [ "$(cat "$AR_DIR/boot" 2>/dev/null | tr -d ' \r\n')" != "${BOOT_ID:-unknown}" ] || \
         [ "$(cat "$AR_DIR/pid" 2>/dev/null | tr -d ' \r\n')" != "$(pidof audioserver 2>/dev/null)" ]; then
        _r=stale
      fi
      ;;
    failed|timeout) ;;
    waiting) ;;
    *) _r=unverified ;;
  esac
  printf '%s\n' "$_r"
}

audio_ready_status() {
  echo "audio_ready=$(audio_ready_state)"
  _why=$(audio_ready_reason)
  [ -n "$_why" ] && echo "audio_ready_reason=$_why"
  return 0
}
