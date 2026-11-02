# ============================================================
# 音频就绪校验器（只读）
# ============================================================
# 输入：$1 = dumpsys media.audio_policy 的输出
#       $2 = dumpsys media.audio_flinger 的输出
# 输出（成功）：primary_output= / primary_hal_frames= / low_latency_out= / raw_out=
# 失败：把原因写到 stderr，退出码 1（调用方按原因字符串分类）
#
# 它回答的问题是：**audioserver 是否真的加载了我们写的端口配置**。
# 只看磁盘文件（mount 后的 /odm）只能证明"文件对"，不能证明"服务读了它"。
#
# 移植自 HyperAudio Switch v3.0 的 bin/check_audio_ready.awk
# （作者 月见里幽瞳 / 海希安的城主），见 CREDITS.md「借鉴与参考」。
# 相对原版增加一个原因 policy_format_unrecognized：当输出里找不到任何可识别
# 结构时，明确区分"格式不认识（→ 无法验证）"与"确实没就绪（→ 判定失败）"，
# 避免在 dumpsys 输出格式不同的机型上误判为故障。
#
# 明确边界：加载了配置不等于能出声，也不等于 Dolby 正在处理。
# ============================================================
# 把 "0x00000004" 这类十六进制标志串转成十进制整数；非法返回 -1
function hexnum(s,    i,d,n) {
    sub(/^0[xX]/,"",s); s=tolower(s); n=0
    for(i=1;i<=length(s);i++) {
        d=index("0123456789abcdef",substr(s,i,1))-1
        if(d<0) return -1
        n=n*16+d
    }
    return n
}

# ---------- 第一份输入：audio_policy ----------
FILENAME==ARGV[1] {
    # 任何可识别的结构都算"格式认得出"
    if (/Primary Output I\/O handle:/) saw_primary=1
    if (/MixPorts/) saw_mixports=1

    if ($0 ~ /^[[:space:]]*Primary Output I\/O handle:[[:space:]]*[0-9]+/) primary=$NF+0

    # 输出条目。两种布局都要认：
    #   A) "  1. Handle: 10; \"primary\""      —— 标注同一行（本机实测这种）
    #   B) "  1. Handle: 10" + 下一行 "; \"primary\""
    # 句柄号必须从 "Handle:" 之后取，不能取 $NF —— 布局 A 的 $NF 是 "primary"。
    if ($0 ~ /^[[:space:]]*[0-9]+\.[[:space:]]*Handle:[[:space:]]*[0-9]+/) {
        cur_handle=0
        if (match($0, /Handle:[[:space:]]*[0-9]+/)) {
            s=substr($0, RSTART, RLENGTH); sub(/^Handle:[[:space:]]*/,"",s); cur_handle=s+0
        }
        in_primary=0; output_ports=0
        if ($0 ~ /;[[:space:]]*"primary"[[:space:]]*$/) { in_primary=1; primary_handle=cur_handle }
        next
    }
    if ($0 ~ /^[[:space:]]*;[[:space:]]*"primary"[[:space:]]*$/) {
        in_primary=1; primary_handle=cur_handle; next
    }

    if(in_primary && /Output MixPorts/) output_ports=1
    if(/Input MixPorts/ || /Audio Routes/) output_ports=0
    if(in_primary && output_ports && $0 ~ /^[[:space:]]*[0-9]+\.[[:space:]]*"(low_latency_out|raw_out)";/) {
        name=($0 ~ /"low_latency_out"/ ? "low_latency_out" : "raw_out")
        counts[name]++
        # 本机实测格式："1. \"low_latency_out\"; 0x0002 (AUDIO_OUTPUT_FLAG_PRIMARY)"
        # —— **没有 flags 关键字**，值直接跟在分号后。按优先级依次尝试：
        #   1) 分号后的十六进制（实测格式）
        #   2) "flags 0x..."（其他版本可能带关键字）
        #   3) 兜底：取最后一个字段
        if (match($0, /;[[:space:]]*0[xX][0-9a-fA-F]+/)) {
            s=substr($0, RSTART, RLENGTH); sub(/^;[[:space:]]*/,"",s)
            flags[name]=hexnum(s)
        } else if (match($0, /flags[[:space:]]+0[xX][0-9a-fA-F]+/)) {
            s=substr($0, RSTART+5, RLENGTH-5); sub(/^[[:space:]]+/,"",s)
            flags[name]=hexnum(s)
        } else {
            s=$0; sub(/^.*;[[:space:]]*/,"",s); sub(/[[:space:]].*$/,"",s)
            flags[name]=hexnum(s)
        }
    }
    next
}

# ---------- 第二份输入：audio_flinger ----------
FILENAME==ARGV[2] {
    if(/^Output thread /) { output_thread=1; thread_io=0 }
    if(/^Input thread / || /^Record thread /) output_thread=0
    if(output_thread && /^[[:space:]]*I\/O handle:[[:space:]]*[0-9]+/) { thread_io=$NF+0; outputs[thread_io]=1 }
    if(output_thread && thread_io>0 && /^[[:space:]]*HAL frame count:[[:space:]]*[0-9]+/) frames[thread_io]=$NF+0
    next
}

END {
    reason=""

    # 顶层没写 Primary Output handle 时，用刚才识别到的 primary 输出兜底
    if (primary<=0 && primary_handle>0) primary=primary_handle

    # 先判"能不能认出来"，再判"就绪没就绪" —— 顺序很重要：
    # 认不出来时不该报成故障，否则换机型就会误判。
    if (!saw_primary && !saw_mixports) reason="policy_format_unrecognized"
    else if (primary<=0) reason="primary_output_not_ready"
    else if (!outputs[primary]) reason="primary_output_missing_in_flinger"
    else if (frames[primary]<=0) reason="primary_hal_buffer_not_ready"
    else if (expected_low!="" && (counts["low_latency_out"]!=1 || flags["low_latency_out"]!=expected_low)) reason="loaded_low_latency_flags_mismatch"
    else if (expected_raw!="" && (counts["raw_out"]!=1 || flags["raw_out"]!=expected_raw)) reason="loaded_raw_flags_mismatch"

    if (reason!="") { print reason > "/dev/stderr"; exit 1 }

    print "primary_output=" primary
    print "primary_hal_frames=" frames[primary]
    if (counts["low_latency_out"]==1) print "low_latency_out=" flags["low_latency_out"]
    if (counts["raw_out"]==1) print "raw_out=" flags["raw_out"]
}
