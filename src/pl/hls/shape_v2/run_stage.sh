#!/bin/bash
# Server side: run one Vitis HLS stage of the v2 shape kernel.
# Usage: run_stage.sh <csim|csynth|cosim|export>
set -eo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ws=$(dirname "$(dirname "$here")")
export SHAPE_HLS_STAGE=$1
export SHAPE_HLS_FIXTURE=$ws/src/shape_fixtures_20260924_v1
export SHAPE_HLS_PROJECT=$ws/work/hls_shape_v2
export SHAPE_HLS_IP_OUTPUT=$ws/src/shape_top_v2_ip.zip
mkdir -p "$ws/logs" "$ws/work"
if [ "$1" = export ]; then rm -f "$SHAPE_HLS_IP_OUTPUT"; fi
source "$HOME/Xilinx/Vitis_HLS/2024.2/settings64.sh" >/dev/null
cd "$ws/work"
vitis_hls -f "$here/run_hls.tcl" > "$ws/logs/hls_$1.log" 2>&1
