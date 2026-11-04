#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"
source /home/lizx/Xilinx/Vivado/2024.2/settings64.sh
mkdir -p sim
xvlog --sv rtl/*.sv tb/tb_knot.sv >sim/compile.log 2>&1
xelab tb_knot -s knot_sim --debug typical >sim/elaborate.log 2>&1
program=$(python3 -c 'import json;print(json.load(open("fixture/program.json"))["program_beat"])')
xsim knot_sim -runall -testplusarg PROGRAM="$program" -testplusarg STALL="${1:-0}" -log sim/run.log >sim/console.log 2>&1
grep 'SV_KNOT_FULL_PASS' sim/console.log
