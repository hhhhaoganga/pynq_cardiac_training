#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"
source /home/lizx/Xilinx/Vivado/2024.2/settings64.sh
mkdir -p arithmetic
xvlog --sv rtl/knot_quant8.sv tb/tb_quant.sv >arithmetic/compile.log 2>&1
xelab tb_quant -s quant_sim --mt 8 >arithmetic/elaborate.log 2>&1
xsim quant_sim -runall -log arithmetic/run.log >arithmetic/console.log 2>&1
grep 'SV_QUANT_EDGE_PASS' arithmetic/console.log
