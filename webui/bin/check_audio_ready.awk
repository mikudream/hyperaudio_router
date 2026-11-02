# Read-only framework check. A loaded profile is not proof of audible playback,
# a successful future game stream, or processing inside Dolby's hardware engine.
function hexnum(s,    i,d,n) {
    sub(/^0[xX]/,"",s); s=tolower(s); n=0
    for(i=1;i<=length(s);i++) {
        d=index("0123456789abcdef",substr(s,i,1))-1
        if(d<0) return -1
        n=n*16+d
    }
    return n
}
FILENAME==ARGV[1] {
    if ($0 ~ /^[[:space:]]*Primary Output I\/O handle:[[:space:]]*[0-9]+/) primary=$NF+0
    if ($0 ~ /^[[:space:]]*[0-9]+\.[[:space:]]*Handle:/) {
        in_primary=($0 ~ /;[[:space:]]*"primary"[[:space:]]*$/); output_ports=0
    }
    if(in_primary && /Output MixPorts/) output_ports=1
    if(/Input MixPorts/ || /Audio Routes/) output_ports=0
    if(in_primary && output_ports && $0 ~ /^[[:space:]]*[0-9]+\.[[:space:]]*"(low_latency_out|raw_out)";/) {
        name=($0 ~ /"low_latency_out"/ ? "low_latency_out" : "raw_out")
        counts[name]++
        s=$0; sub(/^.*;[[:space:]]*/,"",s); sub(/[[:space:]].*$/,"",s)
        flags[name]=hexnum(s)
    }
    next
}
FILENAME==ARGV[2] {
    if(/^Output thread /) { output_thread=1; thread_io=0 }
    if(/^Input thread / || /^Record thread /) output_thread=0
    if(output_thread && /^[[:space:]]*I\/O handle:[[:space:]]*[0-9]+/) { thread_io=$NF+0; outputs[thread_io]=1 }
    if(output_thread && thread_io>0 && /^[[:space:]]*HAL frame count:[[:space:]]*[0-9]+/) frames[thread_io]=$NF+0
}
END {
    reason=""
    if(primary<=0) reason="primary_output_not_ready"
    else if(!outputs[primary]) reason="primary_output_missing_in_flinger"
    else if(frames[primary]<=0) reason="primary_hal_buffer_not_ready"
    else if(expected_low!="" && (counts["low_latency_out"]!=1 || flags["low_latency_out"]!=expected_low)) reason="loaded_low_latency_flags_mismatch"
    else if(expected_raw!="" && (counts["raw_out"]!=1 || flags["raw_out"]!=expected_raw)) reason="loaded_raw_flags_mismatch"
    if(reason!="") { print reason > "/dev/stderr"; exit 1 }
    print "primary_output=" primary
    print "primary_hal_frames=" frames[primary]
    if(counts["low_latency_out"]==1) print "low_latency_out=" flags["low_latency_out"]
    if(counts["raw_out"]==1) print "raw_out=" flags["raw_out"]
}
