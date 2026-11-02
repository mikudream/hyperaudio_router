# Only current ordinary playback tables. Unknown/MMAP layouts stay unclassified.
# TSV-like output: identity|thread|session|sample-rate|underruns|DAP evidence|track type
/^Output thread / {
    live=1; table=0; io="?"; thread=$0
    sub(/^.*name /,"",thread); sub(/,.*/,"",thread); next
}
/^(Input thread|Mmap thread|MMAP|[[:space:]]*Hardware status)/ {live=0; table=0}
live && /^  I\/O handle:/ {io=$3}
live && /^  [0-9]+ Tracks of which / {table=1; next}
/^  (WakeLock|Local log|[0-9]+ Effect Chains)/ {table=0}
live && /Session State Registered Internal Enabled Suspended:/ {effectrow=1; next}
effectrow {
    effectrow=0; session=$1; enabled=$5; suspended=$6
}
live && /- name: DAP/ {
    # Only global session 0 on this same output; don't attribute another session.
    if(session ~ /^0+$/) {
        if(enabled=="y" && suspended=="n") dap[io]="enabled"
        else if(!dap[io]) dap[io]="present"
    }
}
table && !/Type[[:space:]]+Id/ {
    for(j=2;j<NF;j++) if($j=="yes" && $(j-1) ~ /^[0-9]+$/) {
        client=$(j+1); split(client,pair,"/"); p=pair[1]; u=pair[2]; s=j+2
        if(u=="") {u=$(j+2); s=j+3}
        if(p !~ /^[0-9]+$/ || u !~ /^[0-9]+$/) next
        if(pid!="" && (p!=pid || u!=uid)) next
        n++; out[n]=io; name[n]=thread; sess[n]=$s
        key[n]=p "/" u "/" $(j-1) "/" $s "/" io
        rate[n]=$(s+6); if(rate[n] !~ /^[0-9]+$/) rate[n]="?"
        # Android 16/17 suffix includes two boolean columns and a latency marker.
        # Reject differing layouts instead of mistaking a counter for underruns.
        under[n]="?"
        if($(NF-2) ~ /^(true|false)$/ && $(NF-3) ~ /^(true|false)$/ && $(NF-5) ~ /^[0-9]+$/ && $NF ~ /^[a-z]$/) under[n]=$(NF-5)
        kind[n]=($1 ~ /^F[0-9]+$/ ? "FAST" : "ordinary")
        next
    }
}
END {
    for(i=1;i<=n;i++) print key[i] "|" name[i] "|" sess[i] "|" rate[i] "|" under[i] "|" (dap[out[i]]?dap[out[i]]:"unknown") "|" kind[i]
}
