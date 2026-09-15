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
#   setmode <sound|fast>  切换音效/低延迟模式，单行：ok=1\x1fmode=sound
#   save                单行：ok=1 | error=xxx
# ============================================================

MOD=/data/adb/modules/hyperaudio
CONF=$MOD/config.toml
MODEFILE=$MOD/mode
MSW=$MOD/bin/mode_switch.sh
DETECT=$MOD/bin/detect_tuning.sh
DAEMON=$MOD/hyper-audio
TMP=/data/local/tmp/hyperaudio_webui
# 解释器绝对路径。
# 安装时 customize.sh 的 set_perm_recursive 会把文件权限统一设为 0644（无执行
# 位），所以**不能**用 [ -x ] 判断 .sh 是否可用、也不能裸执行 .sh；否则要么
# 得到 126 Permission denied、要么静默走 fallback 分支（WebUI 会表现为
# "helper 无输出" 或"未检测到调音模块"）。
SH=/system/bin/sh
mkdir -p "$TMP" 2>/dev/null

getk() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)/\1/p" "$CONF" 2>/dev/null | head -1; }
flat() { tr '\n' '\037'; }
getmode() {
  M=$(cat "$MODEFILE" 2>/dev/null | tr -d ' \r\n')
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
      # 守护进程状态：一次读取判断，避免多起进程
      if [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then v_run=1; else v_run=0; fi
      printf 'running=%s\n' "$v_run"
      # 二进制是否就位（含执行位）；缺失时低延迟模式无法启动守护进程
      if [ -x "$DAEMON" ]; then v_dok=1; else v_dok=0; fi
      printf 'daemon_ok=%s\n' "$v_dok"
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
      L="module=none name=官方默认调音 version= verified=0 count=0"
    fi
    M=$(echo "$L" | sed -n 's/.*module=\([^ ]*\).*/\1/p')
    N=$(echo "$L" | sed -n 's/.*name=\(.*\) version=.*/\1/p')
    V=$(echo "$L" | sed -n 's/.*version=\(.*\) verified=.*/\1/p')
    F=$(echo "$L" | sed -n 's/.*verified=\([0-9]*\).*/\1/p')
    C=$(echo "$L" | sed -n 's/.*count=\([0-9]*\).*/\1/p')
    printf '%s|%s|%s|%s|%s' "${M:-none}" "${N:-官方默认调音}" "${V:-}" "${F:-0}" "${C:-0}"
    printf '\n'
    ;;

  setmode)
    M="$2"
    case "$M" in sound|fast) ;; *) printf 'error=bad_mode\x1f\n'; exit 0 ;; esac
    if [ -f "$MSW" ]; then
      # mode_switch.sh 内部会一并刷新 module.prop 的「当前模式」前缀
      $SH "$MSW" apply "$M" >/dev/null 2>&1
    else
      # mode_switch.sh 缺失（安装不完整）时的兜底：至少让模式文件生效。
      # 此时无法刷新简介，因为刷新逻辑也在同一个脚本里。
      printf '%s\n' "$M" > "$MODEFILE" 2>/dev/null
      killall audioserver 2>/dev/null
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
    v_enable=$(sed -n 's/.*"enable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_only=$(sed -n   's/.*"only_whitelist"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_ap=$(sed -n     's/.*"audio_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_hp=$(sed -n     's/.*"hal_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)
    v_pp=$(sed -n     's/.*"app_priority"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$IN" | head -1)

    save_kv enable         "$v_enable"
    save_kv only_whitelist "$v_only"
    save_kv audio_priority "$v_ap"
    save_kv hal_priority   "$v_hp"
    save_kv app_priority   "$v_pp"

    # 重建 whitelist 段
    # 渲染用 awk 一次拼成，不用 shell while 循环：循环里 `wc -l` 与实际行数
    # 在末行无换行时会错位，导致**丢掉最后一项**。
    sed -n 's/.*"whitelist"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$IN" \
      | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' | sed '/^$/d' > "$TMP/wl.txt"
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
    if [ "$end" -lt "$total" ]; then tail -n +$((end + 1)) "$CONF" > "$B2"; else : > "$B2"; fi

    {
      cat "$B1"
      render_whitelist
      cat "$B2"
    } > "$TMP/out.toml"
    printf '\n' >> "$TMP/out.toml"

    if [ -s "$TMP/out.toml" ] && grep -q '^whitelist' "$TMP/out.toml"; then
      cp -f "$TMP/out.toml" "$CONF"
      chmod 644 "$CONF" 2>/dev/null
      # 低延迟模式下的参数变更需要重启守护进程才能生效
      M=$(getmode)
      if [ "$M" = "fast" ] && [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then
        pkill -f "$DAEMON" 2>/dev/null
        sleep 1
        cd "$MOD" && setsid ./hyper-audio >> /data/local/tmp/hyper-audio.log 2>&1 < /dev/null &
      fi
      printf 'ok=1\x1f\n'
    else
      cp -f "$TMP/config.toml.bak" "$CONF" 2>/dev/null
      printf 'error=write_failed\x1f\n'
    fi
    ;;

  *)
    printf 'error=unknown_command\x1f\n'
    ;;
esac
