#!/system/bin/sh
# boot.sh —— 开机收尾：标记状态、按已保存的配置启动低延迟 daemon。
# 应用版没有"开机模式"可选，也不做任何端口/属性改写，因此开机流程只剩三件事：
#   1) 建立本次启动的 state 并标记 applied=native；
#   2) 低延迟开关为开时拉起调度 daemon（名单为空时它不会动任何线程）；
#   3) 刷新模块描述。
boot_status() {
    echo "boot_mode=native"
    echo "boot_guard=none"
    echo "boot_result=ok"
    echo "boot_done=yes"
}

boot_run() {
    mkdir -p "$STATE" || return 1
    printf 'native\n' > "$STATE/applied" || return 1
    ll_init || return 1
    if [ -f "$MODDIR/lowlat.conf" ]; then
        ll_read_config || err invalid_lowlat_config || return 1
        if [ "$LL_ENABLED" = 1 ]; then
            ll_ensure_daemon || return 1
        fi
    fi
    update_description
    log "boot: applied=native lowlat_enabled=$(ll_enabled) whitelist=$(count_wl)"
    echo ok=1
    boot_status
    ll_status 2>/dev/null | sed -n '/^ll_state=/p'
    return 0
}
