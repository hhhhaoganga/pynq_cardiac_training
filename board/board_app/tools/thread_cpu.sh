#!/bin/bash
# Per-thread CPU of echo_demo over N seconds (user / system, % of one core).
# Usage: thread_cpu.sh [seconds]   (touches the UI profile trigger at the start)
secs=${1:-5}
pid=$(pgrep -x echo_demo) || exit 1
hz=$(getconf CLK_TCK)
snap() { for t in /proc/"$pid"/task/*; do echo "$(cat "$t"/comm) $(cut -d' ' -f14,15 "$t"/stat)"; done; }
a=$(snap)
touch /tmp/echo_demo_profile
sleep "$secs"
b=$(snap)
paste <(echo "$a") <(echo "$b") | awk -v s="$secs" -v hz="$hz" \
    '{u=($5-$2)*100/hz/s; y=($6-$3)*100/hz/s; if (u+y>0.5) printf "%-11s user %5.1f%%  sys %5.1f%%\n", $1, u, y}'
