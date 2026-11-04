#!/bin/sh
# webui.sh 参数模式回归测试：
# 带包名的动作是 "perapp-add:com.x" 这种形式，case 必须用通配符匹配。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W="$HERE/../webui/bin/webui.sh"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s (期望 %s, 实际 %s)\n' "$1" "$3" "$2"; fi; }

for a in perapp-add perapp-del wl-add wl-del; do
  ck "$a 使用通配模式" "$(grep -v '^[[:space:]]*#' "$W" | grep -c "$a:\*")" "1"
done
ck "无参动作仍为精确模式" "$(grep -c 'router-status:|' "$W")" "1"

printf '  通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
