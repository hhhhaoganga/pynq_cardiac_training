#!/bin/bash
# Server side: regenerate shape_weights_rows.hpp from the frozen weights, run
# csynth, and print the resource / latency / timing summary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ws=$(dirname "$(dirname "$here")")
fixture=$ws/src/shape_fixtures_20260924_v1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
g++ -std=c++14 -O1 -I"$fixture" "$here/gen_rows.cpp" -o "$tmp/gen"
"$tmp/gen" > "$here/shape_weights_rows.hpp"
echo "rows header: $(wc -c < "$here/shape_weights_rows.hpp") bytes, $(grep -c '_rows\[' "$here/shape_weights_rows.hpp") arrays"
set +e
"$here/run_stage.sh" csynth
echo "csynth exit=$?"
grep -E '^ERROR|II Violation|Unable to schedule|HLS 200-(885|880)' "$ws/logs/hls_csynth.log" | head -10 | cut -c1-200
d=$ws/work/hls_shape_v2/solution1/syn/report
r=$d/shape_top_csynth.rpt
grep -A8 '+ Latency:' "$r" | sed -n 6,6p
grep -A18 '== Utilization Estimates' "$r" | grep -E '^\|(FIFO|Instance|Total|Utilization)'
grep 'ap_clk' "$r" | head -1
grep -E '^\s*\|(compute|fc|pool|window)[a-z0-9_]*U0 ' "$r" | tail -n 10 | cut -c1-120
echo "== multipliers"
grep -hoE 'mul_[0-9a-z]+_[0-9a-z]+_[0-9]+_[0-9]+_[0-9]+ +\| +[0-9]+\| +[0-9]+' "$d"/*_csynth.rpt \
    | awk '{print $1}' | sort | uniq -c | sort -rn | head
