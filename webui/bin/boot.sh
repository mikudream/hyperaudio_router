#!/system/bin/sh
# boot.sh —— 开机收尾：标记状态、归一化配置、拉起低延迟 daemon。
# 没有总开关：daemon 常驻，名单为空时它不会动任何线程。
# 音效链路同理：perapp.conf 的 enabled 字段只为兼容 zygisk 负载，恒为 1。
boot_status() {
    echo "boot_mode=native"
    echo "boot_guard=none"
    echo "boot_result=ok"
    echo "boot_done=yes"
}

# 旧版可能留 enabled=0（总开关关闭）。新版没有开关，统一归一化为 1 并同步镜像。
perapp_normalize() {
    _f=$MODDIR/perapp.conf
    [ -f "$_f" ] || return 0
    _e=$(sed -n 's/^enabled=//p' "$_f" 2>/dev/null | head -1)
    [ "$_e" = 1 ] && return 0
    sed -i 's/^enabled=.*/enabled=1/' "$_f" 2>/dev/null || return 0
    chmod 0644 "$_f" 2>/dev/null
    _L=/data/adb/modules/dolbyrouter/perapp.conf  # 旧版兼容镜像
    if [ -d "${_L%/*}" ]; then
        cp -f "$_f" "$_L" 2>/dev/null
        chmod 0644 "$_L" 2>/dev/null
    fi
    log "normalized perapp.conf enabled=1 (switch removed)"
}

boot_run() {
    mkdir -p "$STATE" || return 1
    printf 'native\n' > "$STATE/applied" || return 1
    perapp_normalize
    ll_init || return 1
    if [ -f "$MODDIR/lowlat.conf" ]; then
        ll_read_config || err invalid_lowlat_config || return 1
    fi
    MODDIR="$MODDIR" /system/bin/sh "$MODDIR/bin/router.sh" publish-only >/dev/null 2>&1 || :
    ll_ensure_daemon || return 1
    update_description
    log "boot: applied=native whitelist=$(count_wl)"
    echo ok=1
    boot_status
    ll_status 2>/dev/null | sed -n '/^ll_state=/p'
    return 0
}
