#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"
source /home/lizx/Xilinx/Vivado/2024.2/settings64.sh
mkdir -p sim_axi
xvlog --sv rtl/*.sv tb/tb_axi.sv >sim_axi/compile.log 2>&1
xelab tb_axi -s knot_axi_sim --debug typical --mt 8 >sim_axi/elaborate.log 2>&1
program=$(python3 -c 'import json;print(json.load(open("fixture/program.json"))["program_beat"])')
xsim knot_axi_sim -runall -testplusarg PROGRAM="$program" -testplusarg STALL="${1:-1}" -log sim_axi/run.log >sim_axi/console.log 2>&1
grep 'SV_KNOT_AXI_PASS' sim_axi/console.log
