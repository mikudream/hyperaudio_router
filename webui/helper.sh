#!/system/bin/sh
# ============================================================
# hyperaudio — KernelSU WebUI 后端脚本
# ============================================================
# 重要：本设备的 KernelSU WebUI 中，ksu.exec() 只回传 stdout 的
#       【最后一行】，且不支持 shell 重定向。因此本脚本所有输出都用
#       `tr '\n' '\037'` 压成单行（字段间用 ASCII \x1f 分隔），
#       由前端拆分解析。
#
# 命令：
#   status              单行：mode=..\x1fenable=..\x1f...\x1fwhitelist_begin\x1f<包名>...\x1fwhitelist_end\x1frunning=0|1
#                             另有 applied / pending / boot_guard / overlay，供前端显示恢复状态
#   setmode <sound|fast>  切换音效/低延迟模式，单行：ok=1\x1fmode=sound
#   save                单行：ok=1 | error=xxx
# ============================================================

MOD=/data/adb/modules/hyperaudio
CONF=$MOD/config.toml
MODEFILE=$MOD/mode
STATE=$MOD/state
# 模式状态机。0.4.5 里叫 mode_switch.sh，现在改名为 runtime.sh
# （改副本再 bind + 事务 + 开机护栏 + 回滚）。保留旧名的回退只是为了
# 让"只更新了部分文件"的中间状态也能工作。
MSW=$MOD/bin/runtime.sh
[ -f "$MSW" ] || MSW=$MOD/bin/mode_switch.sh
DETECT=$MOD/bin/detect_tuning.sh
DAEMON=$MOD/hyper-audio
TMP=/data/local/tmp/hyperaudio_webui
# 解释器绝对路径。
# 安装时 customize.sh 的 set_perm_recursive 会把文件权限统一设为 0644（无执行
# 位），所以**不能**用 [ -x ] 判断 .sh 是否可用、也不能裸执行 .sh；否则要么
# 得到 126 Permission denied、要么静默走 fallback 分支（WebUI 会表现为
# "helper 无输出" 或"未检测到调音模块"）。
SH=/system/bin/sh
CR=$(printf '\r')          # 真正的 CR 字节，供内建模式匹配使用
mkdir -p "$TMP" 2>/dev/null

getk() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)/\1/p" "$CONF" 2>/dev/null | head -1; }
flat() { tr '\n' '\037'; }

# ---------------- DolbyRouter（按应用音效）----------------
# 我们**不**改它的代码，只读写它的配置文件：它是独立的 Zygisk 模块，
# 在目标应用进程内 hook createTrack_l() 清掉 FAST|PRIMARY，让那个应用的
# 音轨回落到普通混音轨（从而经过 DAP 音效链）。详见 CREDITS.md。
DOLBY_DIR=$MOD
DOLBY_CONF=$MOD/perapp.conf
DOLBY_SO=$MOD/zygisk/arm64-v8a.so
DOLBY_LEGACY=/data/adb/modules/dolbyrouter/perapp.conf
DOLBY_MAX=64

# 它的 .so 是否已按本机重定位过 mFlags 偏移。
# 判据：清 FAST|PRIMARY 的那两条指令的 imm12（= 偏移/4）：
#   0x3c0 -> 0xF0 -> LDR 字 0xB943C0xx、STR 字 0xB903C0xx
#   0x378 -> 0xDE -> LDR 字 0xB94378xx、STR 字 0xB90378xx
# （Rn<<5 只会落在低 12 位，所以前 5 个十六进制位稳定，Rd 与 Rn 都不影响。）
# 用 od -tx4 取 32 位字再比前缀，避免依赖 readelf/objdump。
# 这一项要读 324KB，成本不低，所以只在 dolby 这个异步动作里做，不进 status。
dolby_offset_state() {
  [ -f "$DOLBY_SO" ] || { printf 'missing'; return; }
  _w=$(od -An -v -tx4 "$DOLBY_SO" 2>/dev/null | tr ' ' '\n' | grep -c '^b943c')
  _s=$(od -An -v -tx4 "$DOLBY_SO" 2>/dev/null | tr ' ' '\n' | grep -c '^b903c')
  _wo=$(od -An -v -tx4 "$DOLBY_SO" 2>/dev/null | tr ' ' '\n' | grep -c '^b9437')
  _so=$(od -An -v -tx4 "$DOLBY_SO" 2>/dev/null | tr ' ' '\n' | grep -c '^b9037')
  if [ "${_w:-0}" -gt 0 ] && [ "${_s:-0}" -gt 0 ]; then
    printf 'ported'
  elif [ "${_wo:-0}" -gt 0 ] && [ "${_so:-0}" -gt 0 ]; then
    printf 'stock'
  else
    printf 'unknown'
  fi
}

dolby_enabled() {
  [ -f "$DOLBY_CONF" ] || { printf '0'; return; }
  _e=$(sed -n 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*\([01]\).*/\1/p' "$DOLBY_CONF" 2>/dev/null | head -1)
  [ "$_e" = "1" ] && printf '1' || printf '0'
}

# 只输出包名（跳过 enabled= 行与注释/空行）
dolby_apps() {
  [ -f "$DOLBY_CONF" ] || return 0
  sed -n 's/^[[:space:]]*app[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' "$DOLBY_CONF" 2>/dev/null
}

dolby_count() { dolby_apps | wc -l | tr -d ' '; }

# 原子重写：先写临时文件再 mv，避免 WebUI 读到半截配置。
# 参数：<enabled 0|1>，包名从 stdin 逐行读入（已校验）。
dolby_write() {
  _en=$1
  _tmp="$TMP/perapp.conf.$$"
  {
    printf 'enabled=%s\n' "$_en"
    while IFS= read -r _a; do
      [ -n "$_a" ] && printf 'app=%s\n' "$_a"
    done
  } > "$_tmp" 2>/dev/null || return 1
  chmod 0644 "$_tmp" 2>/dev/null
  mv -f "$_tmp" "$DOLBY_CONF" 2>/dev/null || return 1
  # 原生负载把名单路径硬编码成 /data/adb/modules/dolbyrouter/perapp.conf，
  # 整合版必须同时写一份到那里，否则 companion 读到 conf=0，永远不命中。
  if [ "$DOLBY_LEGACY" != "$DOLBY_CONF" ]; then
    mkdir -p "${DOLBY_LEGACY%/*}" 2>/dev/null
    cp -f "$DOLBY_CONF" "$DOLBY_LEGACY" 2>/dev/null
    chmod 0644 "$DOLBY_LEGACY" 2>/dev/null
  fi
  return 0
}

# 包名白名单校验：形如 a.b.c，只允许字母数字下划线与点，且不以数字开头。
# 拒绝一切会破坏 conf 格式或造成注入的输入。
dolby_valid_pkg() {
  case "$1" in
    ''|*[!A-Za-z0-9_.]*) return 1 ;;
  esac
  case "$1" in
    *.*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    [0-9]*|.*|*.) return 1 ;;
  esac
  case "$1" in
    *..*) return 1 ;;
  esac
  [ ${#1} -le 120 ] || return 1
  return 0
}

# 用 shell 内建 read + 参数展开读取，避免 cat/tr/命令替换各起一个进程。
# 本设备每个进程约 70ms，而 getmode 在 status/setmode/save 每条命令里都会调用。
# read 读取时默认 IFS 会去掉行首尾的空白，这里再兜底剥掉空白/制表符/CR，
# 使其行为与原先的 `tr -d ' \r\n'` 等价（包括前导空行、空格包裹等畸形输入）。
getmode() {
  M=""
  if [ -f "$MODEFILE" ]; then
    # 读到第一行非空内容为止（read/mv 均为内建，不起进程）
    while IFS= read -r L || [ -n "$L" ]; do
      M=$L
      case "$M" in *[!\ ]*) break ;; esac
      M=""
    done < "$MODEFILE" 2>/dev/null
  fi
  while :; do
    case "$M" in
      ' '*)  M=${M#?} ;;
      '	'*)  M=${M#?} ;;
      "$CR"*) M=${M#?} ;;
      *) break ;;
    esac
  done
  while :; do
    case "$M" in
      *' ')  M=${M%?} ;;
      *'	')  M=${M%?} ;;
      *"$CR") M=${M%?} ;;
      *) break ;;
    esac
  done
  case "$M" in sound|fast) echo "$M" ;; *) echo sound ;; esac
}

# 性能说明：本设备每次启动一个进程固定约 70ms（空脚本 42ms），
# 所以 status 里绝不能用多次 `$(...)` 各起一个进程——6 个参数分开取就是 6 次
# sed，仅此一项就要 400ms+。下面用一次 sed 输出全部 kv，再由 read 就地拆解。
status_kv() {
  sed -n -e 's/^[[:space:]]*enable[[:space:]]*=[[:space:]]*/enable=/p' \
         -e 's/^[[:space:]]*only_whitelist[[:space:]]*=[[:space:]]*/only_whitelist=/p' \
         -e 's/^[[:space:]]*audio_priority[[:space:]]*=[[:space:]]*/audio_priority=/p' \
         -e 's/^[[:space:]]*hal_priority[[:space:]]*=[[:space:]]*/hal_priority=/p' \
         -e 's/^[[:space:]]*app_priority[[:space:]]*=[[:space:]]*/app_priority=/p' \
         "$CONF" 2>/dev/null
}

case "$1" in
  status)
    [ -f "$CONF" ] || { printf 'error=config_not_found\x1f\n'; exit 0; }
    {
      printf 'mode=%s\n' "$(getmode)"

      # 一次 sed 取回全部参数，就地填默认值后再输出
      v_enable=""; v_only=""; v_ap=""; v_hp=""; v_pp=""
      while IFS= read -r line; do
        case "$line" in
          enable=*)         v_enable="${line#enable=}" ;;
          only_whitelist=*) v_only="${line#only_whitelist=}" ;;
          audio_priority=*) v_ap="${line#audio_priority=}" ;;
          hal_priority=*)   v_hp="${line#hal_priority=}" ;;
          app_priority=*)   v_pp="${line#app_priority=}" ;;
        esac
      done <<EOF
$(status_kv)
EOF
      [ -n "$v_enable" ] || v_enable=false
      [ -n "$v_only" ]   || v_only=false
      [ -n "$v_ap" ]     || v_ap=16
      [ -n "$v_hp" ]     || v_hp=20
      [ -n "$v_pp" ]     || v_pp=15
      printf 'enable=%s\n'         "$v_enable"
      printf 'only_whitelist=%s\n' "$v_only"
      printf 'audio_priority=%s\n' "$v_ap"
      printf 'hal_priority=%s\n'   "$v_hp"
      printf 'app_priority=%s\n'   "$v_pp"

      printf 'whitelist_begin\n'
      sed -n '/^[[:space:]]*whitelist[[:space:]]*=/,/\]/p' "$CONF" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'
      printf 'whitelist_end\n'

      # 事务 / 护栏 / 挂载状态：供前端显示"需要恢复"之类提示。
      # 全部用 -f 与内建读，不额外起进程。
      printf 'applied=%s\n' "$(cat "$STATE/applied" 2>/dev/null | tr -d ' \r\n')"
      if [ -f "$STATE/pending" ]; then printf 'pending=1\n'; else printf 'pending=0\n'; fi
      if [ -f "$STATE/boot.failure" ]; then
        printf 'boot_guard=%s\n' "$(head -1 "$STATE/boot.failure" 2>/dev/null | tr -d ' \r\n')"
      else
        printf 'boot_guard=none\n'
      fi
      # 挂载归属：ours=我们叠的层；conflict=路径上挂着别人的层而我们还以为有自己的；
      # none=我们没有任何层（这是最常见的情况，包括"只挂着调音模块自己的层"）。
      #
      # 判定顺序很重要：先看我们自己有没有层。active.xml 不在 => 我们没层 => none，
      # 绝不能拿一个不存在的 active.xml 去比对，否则会把调音模块自己的挂载
      # 误报成 conflict（真机上踩到过）。
      if [ -f "$STATE/active.xml" ] && [ -f "$STATE/target" ]; then
        _tg=$(cat "$STATE/target" 2>/dev/null | tr -d ' \r\n')
        if [ -f "$_tg" ]; then
          _a=$(stat -c '%d:%i' "$STATE/active.xml" 2>/dev/null)
          _b=$(stat -c '%d:%i' "$_tg" 2>/dev/null)
          if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then printf 'overlay=ours\n'
          else printf 'overlay=conflict\n'; fi
        else
          printf 'overlay=none\n'
        fi
      else
        printf 'overlay=none\n'
      fi

      # 守护进程状态：一次读取判断，避免多起进程
      if [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then v_run=1; else v_run=0; fi
      printf 'running=%s\n' "$v_run"
      # 二进制是否就位；用 -f 而非 -x —— 安装时 set_perm_recursive 会把文件设为
      # 0644，用 -x 会假报"守护进程缺失"（service.sh 的 chmod 未必已跑到）
      if [ -f "$DAEMON" ]; then v_dok=1; else v_dok=0; fi
      printf 'daemon_ok=%s\n' "$v_dok"

      # 音频框架是否真的加载了当前配置（0.4.7 起）。
      # 判定规则与 runtime.sh 的 audio_ready_state() 保持一致：
      # 只有 boot_id 与当前 audioserver PID 都对得上时，上次的 passed 才算数。
      _ar=$(cat "$STATE/audio-ready/result.txt" 2>/dev/null | tr -d ' \r\n')
      if [ "$_ar" = passed ]; then
        _bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
        if [ "$(cat "$STATE/audio-ready/boot" 2>/dev/null | tr -d ' \r\n')" != "$_bid" ] || \
           [ "$(cat "$STATE/audio-ready/pid" 2>/dev/null | tr -d ' \r\n')" != "$(pidof audioserver 2>/dev/null)" ]; then
          _ar=stale
        fi
      fi
      case "$_ar" in passed|failed|timeout|waiting|stale) ;; *) _ar=unverified ;; esac
      printf 'audio_ready=%s\n' "$_ar"
      _why=$(head -1 "$STATE/audio-ready/reason.txt" 2>/dev/null | tr -d ' \r\n')
      [ -n "$_why" ] && printf 'audio_ready_reason=%s\n' "$_why"
      # 按应用音效（DolbyRouter）只报"装没装"——一个目录判断，零成本。
      # 偏移是否适配、应用列表要读 324KB 的 .so，走单独的 dolby 动作。
      if [ -d "$DOLBY_DIR" ]; then printf 'dolby_installed=1\n'; else printf 'dolby_installed=0\n'; fi
    } | flat
    printf '\n'
    ;;

  # 调音来源：单独一条命令，供前端在 status 渲染完成后再异步拉取。
  # 检测要遍历全部已安装模块，耗时远高于 status，不能放进关键路径。
  # 输出单行 | 分隔：<目录名>|<显示名>|<版本>|<0|1 校验通过>|<命中模块数>
  # 注意显示名可能含空格与逗号（多模块时形如 "2个调音模块:a,b"），
  # 所以按 " name=" 与 " version=" 这对标记切分，不能用 [^ ]*。
  tuning)
    if [ -f "$DETECT" ]; then
      L=$($SH "$DETECT" 2>/dev/null | head -1)
    else
      L=""
    fi
    # 检测脚本缺失、或存在但输出为空时，统一回落到默认文案。
    # 注意：必须在这里兜底而不是依赖 awk —— awk 收到空输入时不会有任何记录，
    # 其 main 规则根本不执行，printf 也就不会发生（会让前端收到空输出）。
    [ -n "$L" ] || L="module=none name=官方默认调音 version= verified=0 count=0"
    # 一次 awk 拆出全部字段：原先每个字段各跑一次 `echo|sed`，5 个字段就是
    # 10 个进程（约 700ms）。这里把整行作为 awk 的输入，只起 1 个进程。
    # 字段顺序与 detect_tuning.sh 的输出严格一致，可安全按标记前缀切分。
    printf '%s' "$L" | awk '{
      m=""; n=""; v=""; f=""; c=""
      s=$0
      if (match(s, /module=[^ ]*/))   m=substr(s, RSTART+7,  RLENGTH-7)
      if (match(s, /name=.* version=/)) { n=substr(s, RSTART+5, RLENGTH-14) }
      if (match(s, /version=.* verified=/)) { v=substr(s, RSTART+8, RLENGTH-18) }
      if (match(s, /verified=[0-9]+/)) f=substr(s, RSTART+9, RLENGTH-9)
      if (match(s, /count=[0-9]+/))    c=substr(s, RSTART+6, RLENGTH-6)
      if (m == "") m = "none"
      if (n == "") n = "官方默认调音"
      if (f == "") f = "0"
      if (c == "") c = "0"
      printf "%s|%s|%s|%s|%s", m, n, v, f, c
    }'
    printf '\n'
    ;;

  setmode)
    M="$2"
    case "$M" in sound|fast) ;; *) printf 'error=bad_mode\x1f\n'; exit 0 ;; esac

    if [ ! -f "$MSW" ]; then
      # 安装不完整的兜底。原先这里只写模式文件、不打端口补丁、不起守护进程，
      # 却仍回 ok=1 —— 界面会显示"已切换到低延迟模式"，而实际什么都没做。
      # 现在如实回错，不静默降级。
      printf 'error=mode_switch_missing\x1f\n'
      exit 0
    fi

    # apply 失败（缺调音模块 / 端口改写被拒 / 挂载失败 / 回滚）必须如实上报，
    # 并把失败原因透传给界面，而不是一律 ok=1。
    OUT=$($SH "$MSW" apply "$M" 2>&1)
    RC=$?
    if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -q '^ok=1'; then
      REASON=$(printf '%s' "$OUT" | grep -m1 '^error=' | cut -d= -f2-)
      [ -n "$REASON" ] || REASON=apply_failed
      printf 'error=%s\x1f\n' "$REASON"
      exit 0
    fi

    # 把 runtime 的告警原样透传：守护进程没起来（daemon_not_running）、
    # 音频框架未能确认（audio_unverified_*）。前者影响提权，后者影响
    # "我们是否真的切换成功"，两者都必须让界面看得到。
    # 可能的告警最多两条，直接各取一份，避免拼接转义出错。
    _w1=$(printf '%s' "$OUT" | grep -m1 '^warn=' | cut -d= -f2-)
    _w2=$(printf '%s' "$OUT" | grep '^warn=' | sed -n '2p' | cut -d= -f2-)
    _ar=$(printf '%s' "$OUT" | grep -m1 '^audio_ready=' | cut -d= -f2-)
    _vr=$(printf '%s' "$OUT" | grep -m1 '^verified=' | cut -d= -f2-)
    printf 'ok=1\x1fmode=%s\x1faudio_ready=%s\x1fverified=%s\x1f' \
      "$(getmode)" "${_ar:-unverified}" "${_vr:-0}"
    [ -n "$_w1" ] && printf 'warn=%s\x1f' "$_w1"
    [ -n "$_w2" ] && printf 'warn=%s\x1f' "$_w2"
    printf '\n'
    ;;

  # 撤销一切改动，回到系统原始状态（含摘掉我们的挂载、清掉事务/护栏）
  recover)
    OUT=$($SH "$MSW" recover 2>&1)
    RC=$?
    if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -q '^ok=1'; then
      REASON=$(printf '%s' "$OUT" | grep -m1 '^error=' | cut -d= -f2-)
      [ -n "$REASON" ] || REASON=recover_failed
      printf 'error=%s\x1f\n' "$REASON"
      exit 0
    fi
    printf 'ok=1\x1fmode=%s\x1f\n' "$(getmode)"
    ;;

  save)
    IN="$2"
    [ -n "$IN" ] || { printf 'error=no_input\x1f\n'; exit 0; }
    [ -f "$IN" ] || { printf 'error=input_not_found\x1f\n'; exit 0; }
    [ -f "$CONF" ] || { printf 'error=config_not_found\x1f\n'; exit 0; }

    cp -f "$CONF" "$TMP/config.toml.bak" 2>/dev/null

    save_kv() {
      k="$1"; v="$2"
      [ -z "$v" ] && return
      if grep -q "^[[:space:]]*$k[[:space:]]*=" "$CONF"; then
        sed -i "s|^[[:space:]]*$k[[:space:]]*=.*|$k = $v|" "$CONF"
      else
        printf '%s = %s\n' "$k" "$v" >> "$CONF"
      fi
    }
    # 重建 whitelist 段
    # 渲染用 awk 一次拼成，不用 shell while 循环：循环里 `wc -l` 与实际行数
    # 在末行无换行时会错位，导致**丢掉最后一项**。
    WLRAW=$(sed -n 's/.*"whitelist"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$IN")
    echo "$WLRAW" | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' | sed '/^$/d' > "$TMP/wl.txt"

    # 安全守卫（重要）：只要输入里【有】whitelist 这个键，就允许整体替换
    # （包括用户主动清空成空数组这种合法操作）。但如果键在、抽取结果却为空
    # 且原始文本里确实有内容，说明解析失败（JSON 损坏 / 前后端不一致），
    # 此时照常渲染会写出空数组、把用户白名单静默清空却仍回 ok=1 —— 宁可整体
    # 失败也不清空。
    # 注意：不能用 grep -q '"[^"]' 去判断"有内容"——whitelist 后的 `[` 会让它
    # 误判为有内容。改用 wc -c 判断原始文本长度。
    if grep -q '"whitelist"' "$IN" 2>/dev/null; then
      RAWBYTES=$(printf '%s' "$WLRAW" | tr -d '[:space:]' | wc -c | tr -d ' ')
      if [ "${RAWBYTES:-0}" -gt 0 ] && [ ! -s "$TMP/wl.txt" ]; then
        printf 'error=whitelist_parse_failed\x1f\n'
        exit 0
      fi
    else
      # 输入里没有 whitelist 键：保留配置文件里现有的白名单，不要清空
      sed -n '/^[[:space:]]*whitelist[[:space:]]*=/,/\]/p' "$CONF" 2>/dev/null \
        | grep -o '"[^"]*"' | tr -d '"' > "$TMP/wl.txt"
    fi

    v_enable=$(sed -n 's/.*"enable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_only=$(sed -n   's/.*"only_whitelist"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_ap=$(sed -n     's/.*"audio_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_hp=$(sed -n     's/.*"hal_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_pp=$(sed -n     's/.*"app_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)

    # ── 严格校验（配置一律当数据，不做"缺了就跳过"的静默降级）──────────
    # 原先 save_kv 遇到空值就 return，于是畸形输入会**部分写入**：例如只有
    # enable 一项没解析出来时，其余项照写、配置文件进入半新半旧的不一致状态。
    # 现在先在内存里全量校验，任何一项不过就整体拒绝，绝不写出部分结果。
    _bad=""
    case "$v_enable" in true|false) ;; *) _bad="enable" ;; esac
    case "$v_only"   in true|false) ;; *) _bad="${_bad}${_bad:+ }only_whitelist" ;; esac
    for _p in "$v_ap" "$v_hp" "$v_pp"; do
      case "$_p" in
        ''|*[!0-9]*|0*) _bad="${_bad}${_bad:+ }priority" ;;
        *) [ "${#_p}" -le 2 ] && [ "$_p" -ge 1 ] && [ "$_p" -le 99 ] || _bad="${_bad}${_bad:+ }priority" ;;
      esac
    done
    # 白名单项必须是包名形态；含空格/分号/$() 等一律拒绝（这些值会被写进
    # TOML 并由守护进程读取，宁可拒绝也不写入可疑内容）
    if [ -s "$TMP/wl.txt" ]; then
      if grep -qvE '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' "$TMP/wl.txt"; then
        _bad="${_bad}${_bad:+ }whitelist_entry"
      fi
    fi
    if [ -n "$_bad" ]; then
      printf 'error=invalid_value_%s\x1f\n' "$(printf '%s' "$_bad" | tr ' ' '_')"
      exit 0
    fi

    save_kv enable         "$v_enable"
    save_kv only_whitelist "$v_only"
    save_kv audio_priority "$v_ap"
    save_kv hal_priority   "$v_hp"
    save_kv app_priority   "$v_pp"

    render_whitelist() {
      # 逐项拼出 TOML 数组：项间用逗号，最后一项不加逗号
      printf 'whitelist = [\n'
      awk '{ if (NR > 1) printf ",\n"; printf "    \"%s\"", $0 } END { if (NR > 0) printf "\n" }' "$TMP/wl.txt"
      printf ']\n'
    }

    start=$(grep -n '^[[:space:]]*whitelist[[:space:]]*=' "$CONF" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$start" ] || { printf 'error=whitelist_block_not_found\x1f\n'; exit 0; }
    ended=$(tail -n +"$start" "$CONF" | grep -n '\]' | head -1 | cut -d: -f1)
    [ -n "$ended" ] || { printf 'error=whitelist_end_not_found\x1f\n'; exit 0; }
    end=$((start + ended - 1))
    total=$(wc -l < "$CONF" | tr -d ' ')

    B1="$TMP/b1"; B2="$TMP/b2"
    if [ "$start" -gt 1 ]; then head -n $((start - 1)) "$CONF" > "$B1"; else : > "$B1"; fi
    # 白名单段之后的内容：去掉末尾空行再写回，否则每次保存都会多出一个空行，
    # 反复保存会让配置文件持续增长（实测：连存 3 次就多出 3 个空行）。
    if [ "$end" -lt "$total" ]; then
      tail -n +$((end + 1)) "$CONF" | awk '{ if ($0 ~ /^[[:space:]]*$/) { n++; next } while (n > 0) { print ""; n-- } print }' > "$B2"
    else
      : > "$B2"
    fi

    {
      cat "$B1"
      render_whitelist
      cat "$B2"
    } > "$TMP/out.toml"

    if [ -s "$TMP/out.toml" ] && grep -q '^whitelist' "$TMP/out.toml"; then
      cp -f "$TMP/out.toml" "$CONF"
      chmod 644 "$CONF" 2>/dev/null
      # 低延迟模式下的参数变更需要重启守护进程才能生效。
      # 注意：不能用 pkill -f "$DAEMON" —— 进程 cmdline 是 "./hyper-audio"，
      # 与绝对路径不匹配，实测永远杀不掉；改用 pidof + 启动器。
      M=$(getmode)
      if [ "$M" = "fast" ] && [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then
        for _p in $(pidof hyper-audio 2>/dev/null); do kill "$_p" 2>/dev/null; done
        rm -f /data/local/tmp/hyperaudio.pid 2>/dev/null
        sleep 1
        if [ -f "$MOD/bin/start_daemon.sh" ]; then
          setsid $SH "$MOD/bin/start_daemon.sh" >/dev/null 2>&1 < /dev/null
        fi
      fi
      printf 'ok=1\x1f\n'
    else
      cp -f "$TMP/config.toml.bak" "$CONF" 2>/dev/null
      printf 'error=write_failed\x1f\n'
    fi
    ;;

  dolby)
    # 按应用音效（DolbyRouter）。前端在 status 之后单独拉这条：
    # 判定"是否已按本机重定位偏移"要读 324KB 的 .so，不能放进 status。
    _cmd=${2:-status}
    _inst=0; [ -d "$DOLBY_DIR" ] && _inst=1
    _comp=0
    # 整合版里负载名为 hyperaudio，独立版为 dolbyrouter，两种都算已加载
    # toybox grep 对 BRE 的 \| 支持不可靠，用两次独立匹配更稳
    if ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 hyperaudio'; then _comp=1; fi
    if ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 dolbyrouter'; then _comp=1; fi
    if [ "$_inst" = "1" ]; then _off=$(dolby_offset_state); else _off=none; fi
    # 是否内置了 zygisk 负载：区分“通用版”与“整合版”，决定 UI 该说什么
    _pay=0; [ -f "$MOD/zygisk/arm64-v8a.so" ] && _pay=1

    case "$_cmd" in
      status) ;;
      enable|add|del|clear)
        # 三道闸：没装 / 偏移未适配本机 / 没有权限，都不写。
        if [ "$_inst" != "1" ]; then printf 'error=dolby_not_installed\x1f\n'; exit 0; fi
        if [ "$_off" = "stock" ]; then printf 'error=dolby_offset_not_ported\x1f\n'; exit 0; fi
        _en=$(dolby_enabled)
        case "$_cmd" in
          enable)
            case "$3" in 0|1) ;; *) printf 'error=bad_value\x1f\n'; exit 0 ;; esac
            _en=$3
            dolby_apps | dolby_write "$_en" || { printf 'error=write_failed\x1f\n'; exit 0; }
            ;;
          clear)
            printf '0\n' | dolby_write "$_en" || { printf 'error=write_failed\x1f\n'; exit 0; }
            ;;
          add)
            if ! dolby_valid_pkg "$3"; then printf 'error=bad_package\x1f\n'; exit 0; fi
            # 已存在则不重复添加（保持幂等，重复点不会写坏文件）
            if dolby_apps | grep -qx "$3"; then
              :
            else
              if [ "$(dolby_count)" -ge "$DOLBY_MAX" ]; then
                printf 'error=too_many_apps\x1f\n'; exit 0
              fi
              { dolby_apps; printf '%s\n' "$3"; } | dolby_write "$_en" \
                || { printf 'error=write_failed\x1f\n'; exit 0; }
            fi
            ;;
          del)
            if ! dolby_valid_pkg "$3"; then printf 'error=bad_package\x1f\n'; exit 0; fi
            dolby_apps | grep -Fxv "$3" | dolby_write "$_en" \
              || { printf 'error=write_failed\x1f\n'; exit 0; }
            ;;
        esac
        printf 'ok=1\x1f'
        ;;
      *)
        printf 'error=bad_dolby_command\x1f\n'; exit 0 ;;
    esac

    { echo "dolby_installed=$_inst"
    echo "dolby_companion=$_comp"
    echo "dolby_payload=$_pay"
    echo "dolby_offset=$_off"
    echo "dolby_enabled=$(dolby_enabled)"
    echo "dolby_count=$(dolby_count)"
    echo "dolby_apps=$(dolby_apps | tr '\n' ',' | sed 's/,$//')"
    printf 'dolby_apps_begin\n'
    printf 'dolby_apps_end\n'
    } | flat
    ;;

  diag)
    # 只读诊断：生成报告文件并返回路径。全程不修改任何状态。
    if [ ! -f "$MOD/bin/diagnose.sh" ]; then printf 'error=no_diagnose\x1f\n'; exit 0; fi
    _out=$($SH "$MOD/bin/diagnose.sh" --save 2>&1)
    _ok=$(printf '%s\n' "$_out" | sed -n 's/^ok=//p' | head -1)
    _p=$(printf '%s\n' "$_out" | sed -n 's/^path=//p' | head -1)
    if [ "$_ok" = "1" ] && [ -n "$_p" ]; then
      printf 'ok=1\x1fpath=%s\x1f\n' "$_p"
    else
      printf 'error=diag_failed\x1f\n'
    fi
    ;;
  *)
    printf 'error=unknown_command\x1f\n'
    ;;
esac
