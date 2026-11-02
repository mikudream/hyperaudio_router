#!/system/bin/sh
# Bounded, offline rules. Logs are data, never executable shell input.
debug_value() { [ ! -f "$2" ] || sed -n "s/^$1=//p" "$2" | head -n 1; }
debug_mode_label() {
    case "$1" in native) echo 原生模式 ;; sound) echo 音效模式 ;; compat) echo 旧兼容档 ;; *) echo 未记录 ;; esac
}
debug_analyze_dir() (
    AD=$1
    printf '日志摘要 · 本地规则解读\n\n'
    printf '版本：%s\n' "$(debug_value version "$AD/module.prop")"
    BM=$(debug_value applied "$AD/status-before.txt")
    AM=$(debug_value applied "$AD/status-after.txt")
    printf '采集模式：%s → %s\n' "$(debug_mode_label "$BM")" "$(debug_mode_label "$AM")"
    BPF=$AD/boot-status.txt
    [ -f "$BPF" ] || BPF=$AD/status-before.txt
    BP=$(debug_value boot_mode "$BPF")
    case "$BP" in native|sound) printf '已保存的开机选择：%s（与采集时模式分开记录）。\n' "$(debug_mode_label "$BP")" ;; esac
    BG=$(debug_value boot_guard "$BPF")
    case "$BG" in
        ''|none) ;;
        *) echo '开机保护：日志记录到启动或切换异常；自动启动将回原生并暂停调度，已保存参数保留。检查后重新保存开机设置才允许下次重试。' ;;
    esac
    case "$(debug_value boot_result "$BPF")" in
        failed) echo '本次启动应用失败，不能据此确认回退完成；请查看 last_boot.log、技术状态与事务记录。' ;;
        guarded_native) echo '本次启动记录：使用原生回退，低延迟调度暂停。' ;;
    esac
    Q=$(debug_value result "$AD/capture-quality.txt")
    TARGET=$(debug_value target "$AD/capture-quality.txt")
    [ -z "$TARGET" ] || printf '目标应用：%s\n' "$TARGET"
    case "$Q" in
        three_active_samples) echo '采集质量：3 次目标播放现场。' ;;
        partial_samples) echo '采集质量：仅部分现场有效，不能据此做连续对比。' ;;
        target_not_active) echo '采集质量：未等到目标游戏播放；请保持游戏前台并出声后重采。' ;;
        mode_changed) echo '采集质量：采集中切换了模式，不能直接作 A/B 对比。' ;;
        module_disabled) echo '采集质量：采集中模块被禁用。' ;;
        system_snapshot) echo '采集质量：单次系统快照，未核对目标游戏。' ;;
        *) echo '采集质量：旧版或不完整日志，缺少现场质量标记。' ;;
    esac
    STABLE=1
    [ -n "$BM" ] && [ "$BM" = "$AM" ] || STABLE=0
    AS1=$(debug_value audioserver "$AD/status-before.txt")
    AS2=$(debug_value audioserver "$AD/status-after.txt")
    [ -n "$AS1" ] && [ "$AS1" = "$AS2" ] || STABLE=0
    [ "$STABLE" = 1 ] || echo '模式或音频服务身份缺少连续证据，不比较累计欠载值。'
    echo
    HAS=0
    : > "$AD/analysis-tracks.tmp"
    for SN in 01 02 03; do
        SD=$AD/samples/$SN
        [ -s "$SD/audio_flinger.txt" ] || continue
        HAS=1
        PID=$(sed -n 's/^target=[^ ]* pid=\([0-9]*\) uid=.*/\1/p' "$SD/context.txt" 2>/dev/null)
        UIDNUM=$(sed -n 's/^target=[^ ]* pid=[0-9]* uid=\([0-9]*\).*/\1/p' "$SD/context.txt" 2>/dev/null)
        printf '样本 %s（%s）：\n' "$SN" "$(debug_value time "$SD/context.txt")"
        if [ -z "$PID" ] || [ -z "$UIDNUM" ]; then echo '  缺少目标进程身份，不能归属到游戏。'; continue; fi
        awk -v pid="$PID" -v uid="$UIDNUM" -f "$MODDIR/bin/analyze_flinger.awk" "$SD/audio_flinger.txt" > "$AD/analysis-one.tmp"
        debug_print_tracks "$AD/analysis-one.tmp"
        if [ "$(debug_value target_active "$SD/quality.txt")" = yes ]; then
            sed "s/^/$SN|/" "$AD/analysis-one.tmp" >> "$AD/analysis-tracks.tmp"
        fi
    done
    if [ "$HAS" = 0 ]; then
        echo '当前快照中的活动播放（未绑定指定游戏）：'
        if [ -s "$AD/audio_flinger.txt" ]; then
            awk -f "$MODDIR/bin/analyze_flinger.awk" "$AD/audio_flinger.txt" > "$AD/analysis-one.tmp"
            debug_print_tracks "$AD/analysis-one.tmp"
        else echo '  未找到 AudioFlinger 快照。'; fi
    fi
    if [ "$Q" = three_active_samples ] && [ "$STABLE" = 1 ]; then
        awk -F '|' '
        $6 ~ /^[0-9]+$/ {
            k=$2; if(!seen[k,$1]++) {n[k]++; if(n[k]==1) first[k]=$6; else if($6<last[k]) reset[k]=1; last[k]=$6}
        }
        END {for(k in n) if(n[k]==3&&!reset[k]) {
            found=1; d=last[k]-first[k]
            if(d==0) print "欠载计数：同一活动音轨三次均为 " first[k] "，没有新增；不能把历史累计值当成持续欠载。"
            else print "欠载计数：同一活动音轨从 " first[k] " 增至 " last[k] "（+" d "）；存在新增欠载线索，但不能单凭它确定电流声原因。"
        }
        if(!found) print "欠载计数：音轨发生切换、格式无法识别或缺少匹配样本，未计算增量。"}' "$AD/analysis-tracks.tmp"
    fi
    echo
    LL=$(debug_value ll_state "$AD/lowlat-status.txt")
    case "$LL" in error|partial) echo '低延迟：日志记录到调度失败或部分成功，详见包内 lowlat-status.txt。' ;; esac
    TC=$(debug_value count "$AD/tuning-candidates.txt")
    case "$TC" in ''|*[!0-9]*) ;; 0) ;; *) printf '检测到 %s 个已启用调音模块的配置载荷；仅表示配置来源，不能断言作用于本次游戏。\n' "$TC" ;; esac
    echo '解读边界：DAP 标记只说明该输出线程上的全局效果器状态，不证明当前声音经过全部处理，也不证明低音单元实际发声。'
    echo '日志不包含录音，不能凭此确定电流声根因；未识别的格式不会被判为“无音效”。'
    echo '若音效模式有电流声、破音或无声，先恢复原生并重开游戏，再采集同一场景进行对照。'
    rm -f "$AD/analysis-one.tmp" "$AD/analysis-tracks.tmp"
)
debug_print_tracks() {
    if [ ! -s "$1" ]; then echo '  未识别到匹配的活动普通音轨（可能已停止、使用 MMAP 或日志格式不同）。'; return; fi
    head -n 12 "$1" | while IFS='|' read -r ID THREAD SESSION RATE UNDER DAP KIND; do
        printf '  %s · 会话 %s · %s Hz · 音轨 %s\n' "$THREAD" "$SESSION" "$RATE" "$ID"
        case "$KIND" in FAST) echo '  表中标为 FAST 音轨。' ;; ordinary) echo '  当前普通播放表中有活动音轨。' ;; esac
        case "$DAP" in enabled) echo '  同一输出线程：全局 DAP 已启用且未挂起。' ;; present) echo '  同一输出线程：存在全局 DAP，但未读到启用且未挂起的组合。' ;; *) echo '  未取得同一输出的全局 DAP 启用证据。' ;; esac
        printf '  累计欠载值：%s（不是本次电流声次数）。\n' "$UNDER"
    done
}
debug_valid_name() {
    [ "${#1}" -le 100 ] && printf '%s\n' "$1" | grep -Eq '^hyperaudio-(native|sound|compat|unknown)-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz$'
}
debug_reports() {
    for DF in /sdcard/Download/hyperaudio-*.tar.gz; do
        [ -f "$DF" ] && [ ! -L "$DF" ] && debug_valid_name "${DF##*/}" || continue
        printf '%s %s\n' "$(stat -c %Y "$DF" 2>/dev/null)" "${DF##*/}"
    done | sort -rn | head -n 12 | cut -d ' ' -f 2
}
debug_summary() {
    if [ -s "$STATE/debug-last-analysis.txt" ]; then cat "$STATE/debug-last-analysis.txt"
    else echo '暂无解读。采集完成后自动生成，也可以选择 Download 内的旧版诊断包。'; fi
}
debug_analyze() (
    debug_valid_name "$1" || { echo '日志文件名不受支持。'; exit 1; }
    SRC=/sdcard/Download/$1
    [ -f "$SRC" ] && [ ! -L "$SRC" ] || { echo '日志不存在或是链接。'; exit 1; }
    SIZE=$(stat -c %s "$SRC")
    case "$SIZE" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$SIZE" -le 16777216 ] || { echo '日志超过 16 MiB，请在电脑上解读。'; exit 1; }
    umask 077
    mkdir -p "$STATE" || exit 1
    AD=$(mktemp -d "$STATE/debug-read.XXXXXX") || exit 1
    trap 'rm -rf "$AD"' EXIT
    trap 'exit 130' INT TERM HUP
    head -c 16777217 "$SRC" > "$AD/archive.tar.gz" || exit 1
    [ "$(stat -c %s "$AD/archive.tar.gz")" -le 16777216 ] || exit 1
    (timeout 5 tar -tzf "$AD/archive.tar.gz" 2>/dev/null; echo $? > "$AD/list.rc") | head -c 262145 > "$AD/list"
    [ "$(stat -c %s "$AD/list")" -le 262144 ] || { echo '日志目录过大。'; exit 1; }
    [ "$(cat "$AD/list.rc" 2>/dev/null)" = 0 ] || { echo '日志损坏或读取超时。'; exit 1; }
    ANY=0
    # Stream exact allowlisted members into private regular files; never extract
    # an archive tree, use its symlinks or trust an archived analysis.txt.
    for ENTRY in module.prop status-before.txt status-after.txt boot-status.txt capture-quality.txt lowlat-status.txt tuning-candidates.txt audio_flinger.txt samples/01/context.txt samples/01/quality.txt samples/01/audio_flinger.txt samples/02/context.txt samples/02/quality.txt samples/02/audio_flinger.txt samples/03/context.txt samples/03/quality.txt samples/03/audio_flinger.txt; do
        MEMBER=""
        if grep -Fx "./$ENTRY" "$AD/list" >/dev/null; then MEMBER=./$ENTRY
        elif grep -Fx "$ENTRY" "$AD/list" >/dev/null; then MEMBER=$ENTRY; fi
        [ -n "$MEMBER" ] || continue
        case "$ENTRY" in */*) mkdir -p "$AD/data/${ENTRY%/*}" ;; *) mkdir -p "$AD/data" ;; esac
        (timeout 5 tar -xzOf "$AD/archive.tar.gz" "$MEMBER" 2>/dev/null; echo $? > "$AD/member.rc") | head -c 2097153 > "$AD/data/$ENTRY"
        if [ "$(stat -c %s "$AD/data/$ENTRY")" -gt 2097152 ]; then echo '日志成员过大，解读已停止。'; exit 1; fi
        [ "$(cat "$AD/member.rc" 2>/dev/null)" = 0 ] || { echo '日志成员损坏或读取超时。'; exit 1; }
        [ ! -s "$AD/data/$ENTRY" ] || ANY=1
    done
    [ "$ANY" = 1 ] && [ -s "$AD/data/audio_flinger.txt" -o -s "$AD/data/samples/01/audio_flinger.txt" ] || { echo '未找到可读取的音频快照，日志可能损坏或格式不受支持。'; exit 1; }
    { printf '报告：%s\n' "$1"; debug_analyze_dir "$AD/data"; } > "$AD/summary"
    cp "$AD/summary" "$STATE/debug-last-analysis.$$.tmp" && mv "$STATE/debug-last-analysis.$$.tmp" "$STATE/debug-last-analysis.txt" || exit 1
    cat "$AD/summary"
)
