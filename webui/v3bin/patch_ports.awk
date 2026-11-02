# A bounded XML start-tag editor, not a general XML parser.
# Input remains byte-for-byte identical except the two output flags attributes.
# Unsupported constructs, missing/duplicate ports and unknown flag combinations fail closed.
function fail(s) { print "patch_error=" s > "/dev/stderr"; bad=1; exit 2 }
BEGIN {
    if (length(remove_fast)==0) remove_fast=1
    # Legacy remove_fast applies to both ports unless an explicit per-port value is given.
    if (length(remove_fast_low)==0) remove_fast_low=remove_fast
    if (length(remove_fast_raw)==0) remove_fast_raw=remove_fast
    if (length(remove_raw)==0) remove_raw=1
    if (remove_fast !~ /^[01]$/ || remove_fast_low !~ /^[01]$/ || remove_fast_raw !~ /^[01]$/ || remove_raw !~ /^[01]$/) fail("bad_flag_selection")
}
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
        prefix=""; if (f ~ /^AUDIO_OUTPUT_FLAG_/) { prefix="AUDIO_OUTPUT_FLAG_"; sub(/^AUDIO_OUTPUT_FLAG_/,"",f) }
        if (f=="FAST") fast_seen[name]++
        if (f=="RAW") raw_seen[name]++
        if ((f=="FAST" && fast_selected==1) || (f=="RAW" && raw_selected)) { removed[name]++; continue }
        if (f!="PRIMARY" && f!="NONE" && f!="FAST" && f!="RAW") fail("unsupported_flag_" name "_" f)
        if (f=="PRIMARY") primary[name]++
        if (f=="PRIMARY") kept_primary[name]=1
        if (f=="FAST") kept_fast[name]=1
        if (f=="RAW") kept_raw[name]=1
        keep=keep (keep=="" ? "" : sep) prefix f
    }
    if (name=="low_latency_out" && primary[name]!=1) fail("missing_primary")
    if (name=="raw_out" && primary[name]) fail("unexpected_raw_primary")
    # Preserve the 1.0 fail-closed checks for its exact default combination.
    # RAW-only editing legitimately leaves low_latency_out unchanged.
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
    if (report_flags==1) {
        print "low_latency_out=" (2*kept_primary["low_latency_out"]+4*kept_fast["low_latency_out"]+256*kept_raw["low_latency_out"])
        print "raw_out=" (2*kept_primary["raw_out"]+4*kept_fast["raw_out"]+256*kept_raw["raw_out"])
    } else printf "%s",out
}
