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
TMP=/data/local/tmp/hyperaudio_webui
mkdir -p "$TMP" 2>/dev/null

getk() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)/\1/p" "$CONF" 2>/dev/null | head -1; }
flat() { tr '\n' '\037'; }
getmode() {
  M=$(cat "$MODEFILE" 2>/dev/null | tr -d ' \r\n')
  case "$M" in sound|fast) echo "$M" ;; *) echo sound ;; esac
}

# 调音来源（扫描已安装模块 + md5 校验）
# 输出单个 | 分隔的字段，避免与 status 的其它字段混淆：
#   <模块目录名>|<显示名>|<版本>|<0|1 是否校验通过>
tuning_info() {
  if [ -x "$DETECT" ]; then
    L=$(sh "$DETECT" 2>/dev/null | head -1)
  else
    L="module=none name=未检测到调音模块 version= verified=0"
  fi
  M=$(echo "$L" | sed -n 's/.*module=\([^ ]*\).*/\1/p')
  N=$(echo "$L" | sed -n 's/.*name=\(.*\) version=.*/\1/p')
  V=$(echo "$L" | sed -n 's/.*version=\(.*\) verified=.*/\1/p')
  F=$(echo "$L" | sed -n 's/.*verified=\([0-9]*\).*/\1/p')
  printf '%s|%s|%s|%s' "${M:-none}" "${N:-未检测到调音模块}" "${V:-}" "${F:-0}"
}

case "$1" in
  status)
    [ -f "$CONF" ] || { printf 'error=config_not_found\x1f\n'; exit 0; }
    {
      printf 'mode=%s\n'           "$(getmode)"
      printf 'enable=%s\n'         "$(getk enable)"
      printf 'only_whitelist=%s\n' "$(getk only_whitelist)"
      printf 'audio_priority=%s\n' "$(getk audio_priority)"
      printf 'hal_priority=%s\n'   "$(getk hal_priority)"
      printf 'app_priority=%s\n'   "$(getk app_priority)"
      # 调音来源：<目录名>|<显示名>|<版本>|<校验通过>
      printf 'tuning=%s\n' "$(tuning_info)"
      printf 'whitelist_begin\n'
      sed -n '/^[[:space:]]*whitelist[[:space:]]*=/,/\]/p' "$CONF" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'
      printf 'whitelist_end\n'
      # 用 pidof 判断（pgrep -f 在本设备上对已运行进程匹配不稳定）
      if [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then printf 'running=1\n'; else printf 'running=0\n'; fi
    } | flat
    printf '\n'
    ;;

  setmode)
    M="$2"
    case "$M" in sound|fast) ;; *) printf 'error=bad_mode\x1f\n'; exit 0 ;; esac
    if [ -x "$MSW" ]; then
      sh "$MSW" apply "$M" >/dev/null 2>&1
    else
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
    sed -n 's/.*"whitelist"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$IN" \
      | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' | sed '/^$/d' > "$TMP/wl.raw"
    sed -e '$a\' "$TMP/wl.raw" > "$TMP/wl.txt"

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
      printf 'whitelist = [\n'
      sed 's/^/    "/; s/$/",/' "$TMP/wl.txt"
      printf ']\n'
      cat "$B2"
    } > "$TMP/out.toml"
    printf '\n' >> "$TMP/out.toml"

    if [ -s "$TMP/out.toml" ] && grep -q '^whitelist' "$TMP/out.toml"; then
      cp -f "$TMP/out.toml" "$CONF"
      chmod 644 "$CONF" 2>/dev/null
      # 低延迟模式下的参数变更需要重启守护进程才能生效
      M=$(getmode)
      if [ "$M" = "fast" ] && [ -n "$(pidof hyper-audio 2>/dev/null)" ]; then
        pkill -f "$MOD/hyper-audio" 2>/dev/null
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
