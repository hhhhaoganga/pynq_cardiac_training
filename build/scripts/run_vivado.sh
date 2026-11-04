#!/bin/bash
# Usage: run_vivado.sh <script.tcl> <logname> [tclargs...]
# Runs Vivado 2024.2 in batch mode on the build server; logs go to ../logs.
set -eo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ws=$(dirname "$(dirname "$here")")
mkdir -p "$ws/logs"
source "${VIVADO_SETTINGS:-$HOME/Xilinx/Vivado/2024.2/settings64.sh}" >/dev/null
cd "$ws"
script=$1; log=$2; shift 2
vivado -mode batch -notrace -source "$here/$script" \
    -log "$ws/logs/$log.log" -journal "$ws/logs/$log.jou" -tclargs "$@"
