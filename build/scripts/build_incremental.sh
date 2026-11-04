#!/bin/bash
# Build server, from any copy of the workspace (<ws>, <ws>/src, <ws>/ref):
# create the DFX project (wide pblock), point impl_1 at the reference routed
# checkpoint in pynq_dfx/ref_dcp (incremental implementation: a full re-place
# of rm_seg does not route), then implement both RMs, write bitstreams and run
# the gates (WNS/WHS >= 0, DRC 0, pr_verify).
# Usage: bash build_incremental.sh [tag] [strategy]
#   outputs out/shell_dfx_wide_<tag>/, logs in logs/
#   VIVADO_SETTINGS=/path/settings64.sh overrides ~/Xilinx/Vivado/2024.2/settings64.sh
set -eo pipefail
cd "$(dirname "$0")/../.."
tag=${1:-inc}
strategy=${2:-Performance_Retiming}
ref=$(pwd)/ref_dcp
test -f "$ref/impl_1/shell_wrapper_postroute_physopt.dcp" || { echo "missing $ref/impl_1/*.dcp"; exit 1; }
mkdir -p logs
run() { bash run_vivado.sh "$@"; }
echo "[$(date +%T)] create project wide_$tag ($strategy)"
run create_dfx.tcl "create_dfx_wide_$tag" wide "$strategy" "$tag" > /dev/null
echo "[$(date +%T)] incremental reference $ref"
run set_incremental.tcl "inc_$tag" "wide_$tag" "$ref" physopt > /dev/null
echo "[$(date +%T)] implement + bitstreams + gates (about 15 min)"
run build_dfx.tcl "build_dfx_wide_$tag" "wide_$tag" > /dev/null || true
grep -E "DFX_RESULT|PR_VERIFY|SHELL_DFX_BUILD_CHECKED|gate failed|^ERROR" "logs/build_dfx_wide_$tag.log" | head -20
grep -q SHELL_DFX_BUILD_CHECKED "logs/build_dfx_wide_$tag.log" && echo "OK: out/shell_dfx_wide_$tag" || { echo FAILED; exit 1; }
