#!/system/bin/sh
# 只读诊断报告。不修改任何配置、不动挂载、不重启音频服务。
#
# 用途：用户反馈问题时，用它导出一份能直接定位问题的文本，避免反复追问
# "你的模式是什么 / 层挂上了吗 / 框架加载了吗"。
#
# 用法：
#   sh bin/diagnose.sh            # 打到标准输出
#   sh bin/diagnose.sh --save     # 存到 /sdcard/Download（不可用时退到 /data/local/tmp）
#
# 退出码：0 = 报告已生成（各段缺失不影响）；1 = 连输出目录都建不出来。
#
# 隐私：只包含模块自身状态、音频策略/混音器摘要与日志尾部；
# 不读取任何应用数据、不含账号信息。包名列表也只输出前若干项。

MODDIR=${0%/*}
[ "$MODDIR" = "${0%/*}" ] || MODDIR=.
cd "$MODDIR/.." 2>/dev/null || cd "$MODDIR"
MOD=$(pwd)
STATE=$MOD/state

MAXLOG=40          # 每个日志最多取多少行
MAX_WL=15          # 白名单最多列出多少项

have() { command -v "$1" >/dev/null 2>&1; }
prop() { getprop "$1" 2>/dev/null; }

# 取某个文件的前 N 行，缺失时明确写出来而不是静默留空。
head_of() {
  _f=$1; _n=${2:-20}
  if [ -f "$_f" ]; then
    head -n "$_n" "$_f" 2>/dev/null | sed 's/^/  /'
  else
    echo "  (缺失: $_f)"
  fi
}

target_path() {
  _t=$(cat "$STATE/target" 2>/dev/null | tr -d ' \r\n')
  [ -n "$_t" ] || _t=/odm/etc/audio/audio_module_config_primary.xml
  printf '%s' "$_t"
}

report() {
  echo "================ hyperaudio 诊断报告 ================"
  echo "时间      : $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
  echo "系统      : Android $(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
  echo "Root      : $(prop ro.kernel.qemu >/dev/null 2>&1; [ -d /data/adb/ksu ] && echo KernelSU || echo Magisk/其他)"
  echo "内核      : $(uname -r 2>/dev/null)"
  echo ""

  echo "---------------- 模块 ----------------"
  echo "路径      : $MOD"
  echo "版本      : $(sed -n 's/^version=//p' "$MOD/module.prop" 2>/dev/null)"
  echo "versionCode: $(sed -n 's/^versionCode=//p' "$MOD/module.prop" 2>/dev/null)"
  echo "id        : $(sed -n 's/^id=//p' "$MOD/module.prop" 2>/dev/null)"
  echo "模式      : $(cat "$MOD/mode" 2>/dev/null | tr -d ' \r\n')"
  echo "已应用    : $(cat "$STATE/applied" 2>/dev/null | tr -d ' \r\n')"
  echo "待处理    : $([ -f "$STATE/pending" ] && echo yes || echo no)"
  echo "开机护栏  : $([ -f "$STATE/boot.failure" ] && head -1 "$STATE/boot.failure" 2>/dev/null || echo none)"
  echo "按应用音效: $([ -f "$MOD/perapp.conf" ] && echo "有 perapp.conf（$(grep -c '^app=' "$MOD/perapp.conf" 2>/dev/null) 项）" || echo 未启用)"
  echo "zygisk 负载: $(ls "$MOD/zygisk" 2>/dev/null | tr '\n' ' ')"
  echo ""

  echo "---------------- 挂载 ----------------"
  _T=$(target_path)
  echo "目标路径  : $_T"
  echo "该路径上的层:"
  awk -v t="$_T" '$5==t {printf "  %s <- %s (%s)\n", $5, $4, $3}' /proc/self/mountinfo 2>/dev/null
  [ -n "$(awk -v t="$_T" '$5==t' /proc/self/mountinfo 2>/dev/null)" ] || echo "  (无)"
  echo "我们的库覆盖:"
  awk '/libaaudio_internal/ && /hyperaudio/ {printf "  %s <- %s\n", $5, $4}' /proc/self/mountinfo 2>/dev/null
  echo ""

  echo "---------------- 端口 flags（当前生效文件）----------------"
  if [ -f "$_T" ]; then
    sed -n 's/.*<mixPort name="\(low_latency_out\|raw_out\)"[^>]*flags="\([^"]*\)".*/  \1 = \2/p' "$_T" 2>/dev/null
  else
    echo "  (目标文件不存在)"
  fi
  echo ""

  echo "---------------- runtime status ----------------"
  if [ -f "$MOD/bin/runtime.sh" ]; then
    sh "$MOD/bin/runtime.sh" status 2>&1 | sed 's/^/  /'
  else
    echo "  (runtime.sh 缺失)"
  fi
  echo ""

  echo "---------------- 音频就绪校验 ----------------"
  echo "  结果: $(cat "$STATE/audio-ready/result.txt" 2>/dev/null | tr -d ' \r\n')"
  echo "  原因: $(head -1 "$STATE/audio-ready/reason.txt" 2>/dev/null)"
  echo "  期望:"; head_of "$STATE/audio-ready/expected.txt" 5
  echo "  观测:"; head_of "$STATE/audio-ready/observed.txt" 6
  echo "  服务 pid: $(cat "$STATE/audio-ready/pid" 2>/dev/null | tr -d ' \r\n')（当前 $(pidof audioserver 2>/dev/null)）"
  echo ""

  echo "---------------- 音频策略摘要 ----------------"
  if have dumpsys; then
    dumpsys media.audio_policy 2>/dev/null \
      | grep -E 'Primary Output I/O handle|"(low_latency_out|raw_out|deep_buffer_out)";' \
      | head -6 | sed 's/^/  /'
    echo "  （若上面为空，说明 dumpsys 不可用或格式不同，看 audio-ready 的原因）"
  else
    echo "  (无 dumpsys)"
  fi
  echo ""

  echo "---------------- 混音线程摘要 ----------------"
  if have dumpsys; then
    dumpsys media.audio_flinger 2>/dev/null \
      | grep -E '^Output thread|I/O handle:|FastMixer' \
      | head -12 | sed 's/^/  /'
    echo "  DAP 效果链: $(dumpsys media.audio_flinger 2>/dev/null | grep -c 'DAP_offload') 处"
  else
    echo "  (无 dumpsys)"
  fi
  echo ""

  echo "---------------- 调音来源 ----------------"
  if [ -f "$MOD/bin/detect_tuning.sh" ]; then
    sh "$MOD/bin/detect_tuning.sh" 2>&1 | head -2 | sed 's/^/  /'
  else
    echo "  (detect_tuning.sh 缺失)"
  fi
  echo ""

  echo "---------------- 配置（脱敏）----------------"
  if [ -f "$MOD/config.toml" ]; then
    grep -E '^\s*(enable|only_whitelist|audio_priority|hal_priority|app_priority)\s*=' "$MOD/config.toml" 2>/dev/null | sed 's/^/  /'
    _n=$(grep -o '"[^"]*"' "$MOD/config.toml" 2>/dev/null | wc -l | tr -d ' ')
    echo "  白名单条数: $_n"
    echo "  白名单（最多 $MAX_WL 项）:"
    grep -o '"[^"]*"' "$MOD/config.toml" 2>/dev/null | tr -d '"' | head -n "$MAX_WL" | sed 's/^/    /'
  else
    echo "  (config.toml 缺失)"
  fi
  echo ""

  echo "---------------- 日志尾部 ----------------"
  for f in "$MOD"/logs/*.log /data/local/tmp/hyperaudio-init.log /data/local/tmp/hyperaudio-runtime.log; do
    [ -f "$f" ] || continue
    echo "  [$(basename "$f")] 共 $(wc -l < "$f" 2>/dev/null) 行，末 $MAXLOG 行:"
    tail -n "$MAXLOG" "$f" 2>/dev/null | sed 's/^/    /'
  done
  echo "（若上面没有任何 [文件] 行，说明日志文件不存在）"
  echo ""
  echo "================ 报告结束 ================"
}

case "${1:-}" in
  --save)
    TS=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
    [ -n "$TS" ] || TS=unknown
    DEST=
    # 允许覆盖输出目录（测试用，也方便把报告直接写到指定位置）
    if [ -n "${HA_DIAG_DEST:-}" ] && [ -d "$HA_DIAG_DEST" ] && [ -w "$HA_DIAG_DEST" ]; then
      DEST=$HA_DIAG_DEST
    fi
    [ -n "$DEST" ] || for d in /sdcard/Download /storage/emulated/0/Download /data/local/tmp; do
      [ -d "$d" ] && [ -w "$d" ] && { DEST=$d; break; }
    done
    [ -n "$DEST" ] || { echo "error=no_writable_dir"; exit 1; }
    OUT=$DEST/hyperaudio-diag-$TS.txt
    report > "$OUT" 2>&1
    if [ -s "$OUT" ]; then
      echo "ok=1"
      echo "path=$OUT"
      echo "size=$(wc -c < "$OUT" 2>/dev/null | tr -d ' ')"
    else
      echo "error=write_failed"
      exit 1
    fi
    ;;
  --stdout|'')
    report
    ;;
  *)
    echo "用法: sh bin/diagnose.sh [--save|--stdout]"
    exit 2
    ;;
esac
