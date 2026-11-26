#!/system/bin/sh
# Parse only live playback-track tables, never input, MMAP capture or history.
ll_active_clients() {
    LC_ALL=C awk '
    /^[[:space:]]*[A-Za-z]+ thread / {
        live=($1=="Output"); mmap=0; table=0; thread=1
    }
    thread && /type [0-9]+ \(MMAP_PLAYBACK\)/ {live=1; mmap=1; table=0; next}
    thread && /type [0-9]+ \(MMAP_CAPTURE\)/ {live=0; mmap=0; table=0; next}
    /^[[:space:]]*[0-9]+ Tracks of which / && live && !mmap {table=1; remaining=$1; next}
    /^[[:space:]]*[0-9]+ Tracks[[:space:]]*$/ && live && mmap {table=2; remaining=$1; next}
    /^[[:space:]]*(WakeLock|Local log|[0-9]+ Effect Chains|Hardware status)/ {table=0; thread=0; live=0; next}
    table==2 && remaining>0 && $1 ~ /^[0-9]+$/ && NF>=9 {
        if ($1>0 && !seen[$1]++) print $1
        remaining--; next
    }
    table==1 && remaining>0 && !/Type[[:space:]]+Id/ {
        for (i=2;i<NF;i++) if ($i ~ /^(yes|no)$/ && $(i-1) ~ /^[0-9]+$/) {
            n=split($(i+1),c,"/"); pid=c[1]; uid=c[2]
            if (n==1) uid=$(i+2)
            if (n<=2 && pid ~ /^[0-9]+$/ && uid ~ /^[0-9]+$/) {
                remaining--
                if ($i=="yes" && pid>0 && uid>=10000 && !seen[pid]++) print pid
            }
            break
        }
    }'
}
