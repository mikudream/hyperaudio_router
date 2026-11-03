#!/system/bin/sh
# runtime.sh —— 模块级状态、描述文案与汇总输出。
#
# 应用版没有"模式切换"：模块不改端口 XML、不改音频属性、不重启 audioserver。
# 它只做两件事：
#   1) 音效链路名单（perapp.conf）交给 zygisk 负载在目标进程内生效；
#   2) 低延迟链路名单（lowlat.conf）由 daemon 逐线程提优先级。
# 因此这里只剩下状态目录、日志、描述维护和只读汇总。
STATE=$MODDIR/state

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$STATE/events.log"; }
err() { printf 'error=%s\n' "$*"; log "ERROR $*"; return 1; }

# 兼容旧调用点：当前恒为 native（无模式概念）
read_mode() { echo native; }

count_list() {
    # $1=文件 $2=键名前缀
    [ -f "$1" ] || { echo 0; return; }
    grep -c "^[[:space:]]*$2" "$1" 2>/dev/null || echo 0
}

count_wl() {
    [ -f "$MODDIR/lowlat.conf" ] || { echo 0; return; }
    _c=$(sed -n 's/^whitelist=//p' "$MODDIR/lowlat.conf" 2>/dev/null | head -1)
    case "$_c" in ''|-) echo 0 ;; *) printf '%s\n' "$_c" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ' ;; esac
}

ll_enabled() {
    _e=$(sed -n 's/^enabled=//p' "$MODDIR/lowlat.conf" 2>/dev/null | head -1)
    case "$_e" in 0) echo 0 ;; *) echo 1 ;; esac
}

update_description() {
    # 管理器模块列表里直接显示两条链路的当前规模
    _pa=$(count_list "$MODDIR/perapp.conf" 'app=')
    _wl=$(count_wl)
    if [ "$(ll_enabled)" = 1 ]; then
        _ll='低延迟调度已开启'
    else
        _ll='低延迟调度已关闭'
    fi
    _f=$MODDIR/module.prop
    [ -f "$_f" ] || return 0
    _t=$_f.new
    awk -v d="按应用路由：音效名单 ${_pa} 项，低延迟名单 ${_wl} 项；${_ll}。名单外的应用保持系统默认。" '
        /^description=/ && !done { print d; done=1; next }
        { print }
    ' "$_f" > "$_t" 2>/dev/null || { rm -f "$_t"; return 0; }
    mv -f "$_t" "$_f" 2>/dev/null || { rm -f "$_t"; return 0; }
    chmod 0644 "$_f" 2>/dev/null
    return 0
}

status() {
    echo "mode=native"
    echo "applied=native"
    echo "audioserver=$(pidof audioserver 2>/dev/null)"
    echo "ll_enabled=$(ll_enabled)"
    echo "perapp_count=$(count_list "$MODDIR/perapp.conf" 'app=')"
    echo "wl_count=$(count_wl)"
    boot_status
    return 0
}
