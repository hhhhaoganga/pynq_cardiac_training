#!/usr/bin/env bash
set -eo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/run"
mkdir "$out"
exec > "$out/console.log" 2>&1
trap 'rc=$?; echo "$rc" > "$out/run.rc"' EXIT
source /home/lizx/Xilinx/Vitis/2024.2/settings64.sh
cd "$out"
vitis-run --mode hls --tcl "$here/check.tcl"
