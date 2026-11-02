#!/system/bin/sh
# router.sh —— 应用版（hyperaudio_router）的"按应用"后端
#
# 提供两个名单的读写：
#   perapp.conf  → 杜比链路名单（经 zygisk 负载把该应用音轨剥回普通轨）
#   config.toml  → 低延迟链路名单（daemon 只对名单内应用提线程优先级）
#
# 输出一律为 key=value 行，供 bin/webui.sh 包成 rc=N|base64 交给前端。
# 所有写操作都是"临时文件 + mv"的原子替换；包名先校验再落盘。
#
# 便于主机测试：路径可用 HA_MOD_DIR 覆盖。

MODDIR=${MODDIR:-${HA_MOD_DIR:-/data/adb/modules/hyperaudio}}
PERAPP=$MODDIR/perapp.conf
CONF=$MODDIR/config.toml
LEGACY=/data/adb/modules/dolbyrouter/perapp.conf
TMPD=/data/local/tmp

ok()   { printf 'ok=1\n'; }
bad()  { printf 'error=%s\n' "$1"; exit 0; }

valid_pkg() {
  case "$1" in ''|*[!A-Za-z0-9_.]*) return 1 ;; esac
  case "$1" in *.*) ;; *) return 1 ;; esac
  case "$1" in [0-9]*|.*|*.) return 1 ;; esac
  case "$1" in *..*) return 1 ;; esac
  [ ${#1} -le 120 ]
}

perapp_apps() {
  [ -f "$PERAPP" ] || return 0
  sed -n 's/^[[:space:]]*app[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' "$PERAPP" 2>/dev/null
}

perapp_enabled() {
  [ -f "$PERAPP" ] || { printf '0'; return; }
  _e=$(sed -n 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*\([01]\).*/\1/p' "$PERAPP" 2>/dev/null | head -1)
  [ "$_e" = "1" ] && printf '1' || printf '0'
}

wl_apps() {
  [ -f "$CONF" ] || return 0
  sed -n '/^[[:space:]]*whitelist[[:space:]]*=/,/]/p' "$CONF" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'
}

# 原子写 perapp.conf，再从 stdin 读包名（一行一个）
write_perapp() {
  _en=$1
  _tmp="$TMPD/router_perapp.$$"
  mkdir -p "$TMPD" 2>/dev/null
  {
    printf 'enabled=%s\n' "$_en"
    while IFS= read -r _a; do
      [ -n "$_a" ] && printf 'app=%s\n' "$_a"
    done
  } > "$_tmp" 2>/dev/null || return 1
  mv -f "$_tmp" "$PERAPP" 2>/dev/null || return 1
  chmod 0644 "$PERAPP" 2>/dev/null
  # zygisk 负载的路径是编译期写死的，必须同步镜像一份，否则 companion 读不到
  if [ -d "${LEGACY%/*}" ] || mkdir -p "${LEGACY%/*}" 2>/dev/null; then
    cp -f "$PERAPP" "$LEGACY" 2>/dev/null
    chmod 0644 "$LEGACY" 2>/dev/null
  fi
  return 0
}

cmd_status() {
  _apps=$(perapp_apps | tr '\n' ',' | sed 's/,$//')
  _n=$(perapp_apps | wc -l | tr -d ' ')
  _wl=$(wl_apps | tr '\n' ',' | sed 's/,$//')
  _wn=$(wl_apps | wc -l | tr -d ' ')
  _pay=0; [ -f "$MODDIR/zygisk/arm64-v8a.so" ] && _pay=1
  _comp=0
  ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 hyperaudio' && _comp=1
  ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 dolbyrouter' && _comp=1

  printf 'perapp_enabled=%s\n' "$(perapp_enabled)"
  printf 'perapp_count=%s\n' "$_n"
  printf 'perapp_apps=%s\n' "$_apps"
  printf 'perapp_payload=%s\n' "$_pay"
  printf 'perapp_companion=%s\n' "$_comp"
  printf 'wl_count=%s\n' "$_wn"
  printf 'wl_apps=%s\n' "$_wl"
  printf 'ok=1\n'
}

cmd_perapp_add() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  perapp_apps | grep -qx "$_p" && { ok; return; }
  { perapp_apps; printf '%s\n' "$_p"; } | write_perapp "$(perapp_enabled)" || bad write_failed
  ok
}

cmd_perapp_del() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  perapp_apps | grep -Fxv "$_p" | write_perapp "$(perapp_enabled)" || bad write_failed
  ok
}

cmd_perapp_enable() {
  case "$1" in 0|1) ;; *) bad bad_value ;; esac
  perapp_apps | write_perapp "$1" || bad write_failed
  ok
}

cmd_wl_add() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  wl_apps | grep -qx "$_p" && { ok; return; }
  [ -f "$CONF" ] || bad no_config
  _tmp="$TMPD/router_conf.$$"
  awk -v p="$_p" '
    /^[[:space:]]*whitelist[[:space:]]*=/ && !done { print; print "    \"" p "\","; done=1; next }
    { print }
  ' "$CONF" > "$_tmp" 2>/dev/null || bad write_failed
  mv -f "$_tmp" "$CONF" || bad write_failed
  chmod 0644 "$CONF" 2>/dev/null
  ok
}

cmd_wl_del() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  [ -f "$CONF" ] || bad no_config
  _tmp="$TMPD/router_conf.$$"
  grep -Fv "\"$_p\"" "$CONF" > "$_tmp" 2>/dev/null || bad write_failed
  mv -f "$_tmp" "$CONF" || bad write_failed
  chmod 0644 "$CONF" 2>/dev/null
  ok
}

case "$1" in
  router-status)  cmd_status ;;
  perapp-add)     cmd_perapp_add "$2" ;;
  perapp-del)     cmd_perapp_del "$2" ;;
  perapp-enable)  cmd_perapp_enable "$2" ;;
  wl-add)         cmd_wl_add "$2" ;;
  wl-del)         cmd_wl_del "$2" ;;
  *)              bad bad_action ;;
esac
