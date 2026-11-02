# Only current AudioFlinger output-track tables. Never interpret Local log history.
/^[A-Za-z]+ thread / { live=($1=="Output"); table=0; mmap=0 }
/type [0-9]+ \(MMAP_PLAYBACK\)/ { live=1; mmap=1 }
/type [0-9]+ \(MMAP_CAPTURE\)/ { live=0; table=0; mmap=0 }
/^  [0-9]+ Tracks of which / && live { table=1; next }
/^  [0-9]+ Tracks[[:space:]]*$/ && live && mmap { table=2; remaining=$1; next }
/^  (WakeLock|Local log|[0-9]+ Effect Chains)/ { table=0 }
table==2 && remaining>0 && $1 ~ /^[0-9]+$/ && NF>=9 {
    if ($1>0 && !seen[$1]++) print $1
    remaining--; next
}
table==1 && !/Type[[:space:]]+Id/ {
    for (i=1;i<NF;i++) if ($i=="yes") {
        split($(i+1),c,"/"); pid=c[1]; uid=c[2]
        if (uid=="") uid=$(i+2)
        if (pid ~ /^[0-9]+$/ && uid ~ /^[0-9]+$/ && pid>0 && uid>=10000 && !seen[pid]++) print pid
        break
    }
}
