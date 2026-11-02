# Input: Android `cmd font dump sans-serif`. Select the normal UI face and the
# Simplified Chinese fallback from the CURRENT service configuration, not a
# guessed font filename in a theme directory. Output is data, never shell code.
function flush() {
    if (bestpath != "" && !chosen[role] && role != "") {
        print role "|" bestpath "|" bestindex
        chosen[role] = 1
    }
    bestpath = ""; bestscore = 10000; bestindex = 0
}
BEGIN { role = ""; families = 0; bestscore = 10000 }
/^[[:space:]]*Family:/ {
    flush(); families++
    role = ""
    if ($0 ~ /langTag[[:space:]]*=[[:space:]]*.*zh(-Hans|-CN|[ ,]|$)/) role = "han"
    else if (families == 1 && $0 !~ /langTag[[:space:]]*=/) role = "latin"
    next
}
/path[[:space:]]*=/ {
    if (role == "" || chosen[role]) next
    line = $0
    if (line !~ /weight[[:space:]]*=[[:space:]]*[0-9]+/ || line !~ /slant[[:space:]]*=[[:space:]]*0[ } ,]/) next
    weight = line; sub(/^.*weight[[:space:]]*=[[:space:]]*/, "", weight); sub(/[^0-9].*$/, "", weight)
    score = weight - 400; if (score < 0) score = -score
    path = line; sub(/^.*path[[:space:]]*=[[:space:]]*/, "", path); sub(/,[[:space:]]*(index|axes)[[:space:]]*=.*$/, "", path); sub(/[[:space:]]+$/, "", path)
    member = 0
    if (line ~ /index[[:space:]]*=/) { member = line; sub(/^.*index[[:space:]]*=[[:space:]]*/, "", member); sub(/[^0-9].*$/, "", member) }
    # FontFace cannot select a named TTC member. Leave nonzero members to the
    # WebView's own system fallback instead of silently using another member.
    if (member != 0 || path !~ /^\// || path ~ /[|\r\n]/) next
    if (score < bestscore) { bestscore = score; bestpath = path; bestindex = member }
}
END { flush() }
