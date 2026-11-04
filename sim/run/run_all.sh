#!/usr/bin/env bash
# Run every profile_rtl testbench in parallel.
#
#   ./run_all.sh [jobs]      default 40 parallel jobs
#
# Results land in ./jobs/<tb>/{elaborate.log,console.log} and a one-line
# summary goes to runall.out.  Set PROFILE_RTL if the RTL is not in
# ../profile_rtl_src, and VIVADO if Vivado 2024.2 is not under ~/Xilinx.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
P=${1:-40}
W=${PROFILE_RTL:-$HERE/../profile_rtl_src}

cd "$W" || exit 1
ls *_tb.sv | sed 's/\.sv$//' > tb_list.txt
echo "testbenches: $(wc -l < tb_list.txt)"

mkdir -p "$HERE/jobs"
nohup xargs -a tb_list.txt -P "$P" -I{} bash "$HERE/run_one.sh" {} \
    > "$HERE/runall.out" 2>&1 &
echo "started pid=$!"
