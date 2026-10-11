# ============================================================
# 有界 XML 起始标签编辑器 —— 只改两个 output 端口的 flags
# ============================================================
# 不是通用 XML 解析器：输入除目标 flags 属性外**逐字节保持不变**。
# 任何不支持的构造、端口缺失/重复、未知 flag 组合都 fail-closed
# （非零退出且 stdout 为空），调用方据此放弃并回滚，绝不写出半成品。
#
# 移植自 HyperAudio Switch 2.0 的 bin/patch_ports.awk（作者 HLMC离开 等），
# 见 CREDITS.md「借鉴与参考」。相对原版的差异：
#   · 去掉其 compat 模式特有的语义，只保留本模块需要的两个端口
#   · 参数命名沿用本模块：remove_fast_low / remove_fast_raw / remove_raw
#
# 调用：awk -v remove_fast_low=1 -v remove_fast_raw=1 -v remove_raw=1 \
#            -f patch_ports.awk < base.xml > candidate.xml
#   remove_fast_low=1  摘掉 low_latency_out 的 FAST
#   remove_fast_raw=1  摘掉 raw_out 的 FAST
#   remove_raw=1       摘掉 raw_out 的 RAW
# 三者全 0 时本编辑器不做任何改动（调用方应据此判定"无需补丁"）。
# ============================================================
function fail(s) { print "patch_error=" s > "/dev/stderr"; bad=1; exit 2 }
BEGIN {
    if (length(remove_fast_low)==0) remove_fast_low=1
    if (length(remove_fast_raw)==0) remove_fast_raw=1
    if (length(remove_raw)==0)      remove_raw=1
    if (remove_fast_low !~ /^[01]$/ || remove_fast_raw !~ /^[01]$/ || remove_raw !~ /^[01]$/) fail("bad_flag_selection")
}
# 取属性值；返回空串表示不存在，同时把值的起止写入全局 as/al、引号写入 aq
function attr(s, key,   pat,t,q,i) {
    pat="[[:space:]]" key "[[:space:]]*=[[:space:]]*[\042\047]"
    if (!match(s,pat)) { as=0; al=0; aq=""; return "" }
    as=RSTART; t=substr(s,RSTART+RLENGTH); q=substr(s,RSTART+RLENGTH-1,1)
    i=index(t,q); if (!i) fail("unterminated_attribute")
    al=RLENGTH+i; aq=q
    return substr(t,1,i-1)
}
function edit(tag,   name,role,flags,s,l,q,n,a,i,f,prefix,keep,sep,fast_selected,raw_selected) {
    name=attr(tag,"name")
    if (name!="low_latency_out" && name!="raw_out") return tag
    fast_selected=(name=="low_latency_out" ? remove_fast_low : remove_fast_raw)
    raw_selected=(name=="raw_out" && remove_raw==1)
    count[name]++
    if (count[name]>1) fail("duplicate_port_" name)
    role=attr(tag,"role")
    if (role!="source") fail("not_output_" name)
    flags=attr(tag,"flags"); s=as; l=al; q=aq
    if (!s) fail("missing_flags_" name)
    if (flags ~ /&/) fail("encoded_flags")
    sep=(index(flags,"|") ? "|" : " ")
    n=split(flags,a,/[[:space:]|]+/); keep=""
    for (i=1;i<=n;i++) {
        f=a[i]; if (f=="") continue
        prefix=""
        if (f ~ /^AUDIO_OUTPUT_FLAG_/) { prefix="AUDIO_OUTPUT_FLAG_"; sub(/^AUDIO_OUTPUT_FLAG_/,"",f) }
        if (f=="FAST") fast_seen[name]++
        if (f=="RAW") raw_seen[name]++
        if ((f=="FAST" && fast_selected==1) || (f=="RAW" && raw_selected)) { removed[name]++; continue }
        if (f!="PRIMARY" && f!="NONE" && f!="FAST" && f!="RAW") fail("unsupported_flag_" name "_" f)
        if (f=="PRIMARY") primary[name]++
        keep=keep (keep=="" ? "" : sep) prefix f
    }
    if (name=="low_latency_out" && primary[name]!=1) fail("missing_primary")
    if (name=="raw_out" && primary[name]) fail("unexpected_raw_primary")
    # 只摘不存在的标志，说明这份配置已被改过或格式不符 —— 拒绝，避免二次改写
    if (fast_selected==1 && fast_seen[name]!=1) fail("already_modified_" name)
    if (raw_selected && raw_seen[name]!=1) fail("already_modified_" name)
    if (keep=="") return substr(tag,1,s-1) substr(tag,s+l)
    return substr(tag,1,s-1) " flags=" q keep q substr(tag,s+l)
}
{ xml=xml $0 "\n" }
END {
    if (bad) exit 2
    if (xml !~ /<mixPorts([[:space:]>])/ || xml !~ /<\/mixPorts[[:space:]]*>/) fail("missing_mixPorts")
    out=""; pos=1; total=length(xml)
    while (pos<=total) {
        k=index(substr(xml,pos),"<")
        if (!k) { out=out substr(xml,pos); break }
        k=pos+k-1; out=out substr(xml,pos,k-pos)
        if (substr(xml,k,4)=="<!--") {
            e=index(substr(xml,k+4),"-->"); if (!e) fail("unterminated_comment")
            len=4+e-1+3; out=out substr(xml,k,len); pos=k+len; continue
        }
        if (substr(xml,k,2)=="<!") fail("unsupported_xml_declaration")
        quote=""; e=0
        for (j=k+1;j<=total;j++) {
            c=substr(xml,j,1)
            if (quote!="") { if (c==quote) quote="" }
            else if (c=="\042" || c=="\047") quote=c
            else if (c==">") { e=j; break }
        }
        if (!e) fail("unterminated_tag")
        tag=substr(xml,k,e-k+1)
        if (tag ~ /^<mixPort[[:space:]]/) tag=edit(tag)
        out=out tag; pos=e+1
    }
    if (count["low_latency_out"]!=1 || count["raw_out"]!=1) fail("required_ports_not_found")
    printf "%s",out
}
