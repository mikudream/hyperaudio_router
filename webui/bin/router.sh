#!/system/bin/sh
# router.sh —— 应用版（hyperaudio_router）的"按应用"后端
#
# 两个名单，各自独立生效，名单外应用一律交给系统：
#   perapp.conf  → 音效链路名单。zygisk 负载剥掉名单内应用的 FAST|PRIMARY 标志，
#                  使其回落到普通混音轨、经过 Dolby 效果链。
#   lowlat.conf  → 低延迟链路名单（whitelist=CSV）。只有名单内应用放音时，
#                  daemon 才把它的音频线程提为 SCHED_FIFO。
#
# 同一包不会同时留在两个名单里：加入一边会自动从另一边移出，并回显 moved_from=。
# 所有写操作都是"临时文件 + mv"的原子替换；包名先校验再落盘。
# 便于主机测试：路径可用 HA_MOD_DIR 覆盖。

MODDIR=${MODDIR:-${HA_MOD_DIR:-/data/adb/modules/hyperaudio}}
PERAPP=$MODDIR/perapp.conf
CONF=$MODDIR/lowlat.conf
LEGACY=/data/adb/modules/dolbyrouter/perapp.conf
TMPD=/data/local/tmp

ok()  { printf 'ok=1\n'; }
bad() { printf 'error=%s\n' "$1"; exit 0; }

valid_pkg() {
  case "$1" in ''|*[!A-Za-z0-9_.]*) return 1 ;; esac
  case "$1" in *.*) ;; *) return 1 ;; esac
  case "$1" in [0-9]*|.*|*.) return 1 ;; esac
  case "$1" in *..*) return 1 ;; esac
  [ ${#1} -le 120 ]
}

tmpfile() { mkdir -p "$TMPD" 2>/dev/null; printf '%s/router_%s.%s' "$TMPD" "$1" "$$"; }

# ---------------- 音效链路（perapp.conf） ----------------

perapp_apps() {
  [ -f "$PERAPP" ] || return 0
  sed -n 's/^[[:space:]]*app[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' "$PERAPP" 2>/dev/null
}

# 原子写 perapp.conf：第一行 enabled（恒为 1，仅为兼容 zygisk 负载），随后一行一个 app=
write_perapp() {
  _tmp=$(tmpfile perapp)
  {
    printf 'enabled=1\n'
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
  publish_props
  return 0
}

perapp_rm() {
  _p=$1
  perapp_apps | grep -Fxv "$_p" | write_perapp
}

# ---------------- 低延迟链路（lowlat.conf） ----------------

conf_val() {
  [ -f "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null | head -1
}

wl_apps() {
  _csv=$(conf_val whitelist)
  case "$_csv" in ''|-) return 0 ;; esac
  printf '%s\n' "$_csv" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

# 把两份名单发布到系统属性，供 zygisk 负载在 app 进程里读取
# （preAppSpecialize 阶段读不到 /data/adb，属性是唯一可靠通道）。
# ha.perapp.app.N → 音效名单；ha.mmap_gate.N → 低延迟名单。
publish_props() {
  command -v setprop >/dev/null 2>&1 || return 0
  _pub() {
    _i=0; _buf=''
    while IFS= read -r _p; do
      [ -z "$_p" ] && continue
      if [ -n "$_buf" ] && [ $(( ${#_buf} + ${#_p} + 1 )) -gt 80 ]; then
        setprop "ha.$1.$_i" "$_buf"; _i=$((_i+1)); _buf=$_p
      else
        if [ -n "$_buf" ]; then _buf="$_buf,$_p"; else _buf=$_p; fi
      fi
    done
    if [ -n "$_buf" ]; then setprop "ha.$1.$_i" "$_buf"; _i=$((_i+1)); fi
    while [ "$_i" -lt 8 ]; do setprop "ha.$1.$_i" '-'; _i=$((_i+1)); done
  }
  perapp_apps | _pub perapp.app
  wl_apps | _pub mmap_gate
}

conf_num() {
  # $1=key $2=default；非法值回落到默认
  _v=$(conf_val "$1")
  case "$_v" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  case "$_v" in 0*) printf '%s' "$2"; return ;; esac
  [ "$_v" -ge 1 ] && [ "$_v" -le 99 ] && printf '%s' "$_v" || printf '%s' "$2"
}

# 原子写 lowlat.conf；保留三个优先级，只替换白名单
write_whitelist() {
  _wl_csv=$1
  _wl_h=$(conf_num hal_priority 20)
  _wl_a=$(conf_num audio_priority 16)
  _wl_p=$(conf_num app_priority 15)
  _tmp=$(tmpfile lowlat)
  {
    printf 'hal_priority=%s\n' "$_wl_h"
    printf 'audio_priority=%s\n' "$_wl_a"
    printf 'app_priority=%s\n' "$_wl_p"
    printf 'whitelist=%s\n' "$_wl_csv"
    printf 'revision=%s-%s\n' "$(date +%s)" "$$"
  } > "$_tmp" 2>/dev/null || return 1
  mv -f "$_tmp" "$CONF" 2>/dev/null || return 1
  chmod 0644 "$CONF" 2>/dev/null
  publish_props
  return 0
}

# ---------------- 动作 ----------------

# 名单变化后刷新 module.prop 描述（管理器的模块列表里直接可见）。
# 在子 shell 里加载 runtime.sh，避免与本脚本的变量互相污染。
refresh_description() {
  [ -f "$MODDIR/bin/runtime.sh" ] || return 0
  ( . "$MODDIR/bin/runtime.sh"; update_description ) >/dev/null 2>&1 || :
  return 0
}

cmd_status() {
  _apps=$(perapp_apps | tr '\n' ',' | sed 's/,$//')
  _n=$(perapp_apps | wc -l | tr -d ' ')
  _wl=$(wl_apps | tr '\n' ',' | sed 's/,$//')
  _wn=$(wl_apps | wc -l | tr -d ' ')
  _pay=0; [ -s "$MODDIR/zygisk/arm64-v8a.so" ] && _pay=1
  _comp=0
  ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 hyperaudio' && _comp=1
  ps -A 2>/dev/null | grep -q 'zn-zygisk-companion64 dolbyrouter' && _comp=1

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
  _moved=0
  if wl_apps | grep -Fxq "$_p"; then
    _rest=$(wl_apps | grep -Fxv "$_p" | tr '\n' ',' | sed 's/,$//')
    write_whitelist "$_rest" || bad write_failed
    _moved=1
  fi
  if perapp_apps | grep -Fxq "$_p"; then
    ok; [ "$_moved" = 1 ] && printf 'moved_from=lowlat\n'; refresh_description; return
  fi
  { perapp_apps; printf '%s\n' "$_p"; } | write_perapp || bad write_failed
  ok
  [ "$_moved" = 1 ] && printf 'moved_from=lowlat\n'
  refresh_description
  return 0
}

cmd_perapp_del() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  [ -f "$PERAPP" ] || { ok; return; }
  perapp_rm "$_p" || bad write_failed
  ok
  refresh_description
}

cmd_wl_add() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  _moved=0
  if perapp_apps | grep -Fxq "$_p"; then
    perapp_rm "$_p" || bad write_failed
    _moved=1
  fi
  wl_apps | grep -Fxq "$_p" && { ok; [ "$_moved" = 1 ] && printf 'moved_from=sound\n'; refresh_description; return; }
  _csv=$(wl_apps | tr '\n' ',' | sed 's/,$//')
  case "$_csv" in '') _wl=$_p ;; *) _wl=$_csv,$_p ;; esac
  write_whitelist "$_wl" || bad write_failed
  ok
  [ "$_moved" = 1 ] && printf 'moved_from=sound\n'
  refresh_description
  return 0
}

cmd_wl_del() {
  _p=$1
  valid_pkg "$_p" || bad bad_package
  wl_apps | grep -Fxq "$_p" || { ok; return; }
  _rest=$(wl_apps | grep -Fxv "$_p" | tr '\n' ',' | sed 's/,$//')
  write_whitelist "$_rest" || bad write_failed
  ok
  refresh_description
}

case "$1" in
  router-status)  cmd_status ;;
  perapp-add)     cmd_perapp_add "$2" ;;
  perapp-del)     cmd_perapp_del "$2" ;;
  wl-add)         cmd_wl_add "$2" ;;
  wl-del)         cmd_wl_del "$2" ;;
  publish-only)   publish_props ;;
  *)              bad bad_action ;;
esac
