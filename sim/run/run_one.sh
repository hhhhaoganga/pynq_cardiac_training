#!/usr/bin/env bash
# Run one profile_rtl testbench.
#
#   ./run_one.sh <tb_name>          e.g. ./run_one.sh camus_axi_ctrl_tb
#
# Assumes the profile_rtl sources sit next to this script in ../profile_rtl_src
# (or set PROFILE_RTL to point at them).  Vivado 2024.2 is expected under
# ~/Xilinx/Vivado/2024.2 -- change VIVADO if it lives elsewhere.
#
# Each run gets its own directory so several testbenches can run at once.
set -u

VIVADO=${VIVADO:-$HOME/Xilinx/Vivado/2024.2}
W=${PROFILE_RTL:-$(cd "$(dirname "$0")/../profile_rtl_src" 2>/dev/null && pwd)}
TB=$1

if [ -z "${W:-}" ] || [ ! -d "$W" ]; then
    echo "profile_rtl sources not found; set PROFILE_RTL to the directory holding *.sv" >&2
    exit 9
fi

J=$(pwd)/jobs/$TB
mkdir -p "$J"
cd "$J" || exit 9

source "$VIVADO/settings64.sh" >/dev/null 2>&1

# Compile the library once into $W/xsim.dir, then hand each job its own copy.
if [ ! -d "$W/xsim.dir" ]; then
    ( cd "$W" && xvlog --sv ./*.sv > "$W/compile.log" 2>&1 ) || {
        echo "COMPILE_FAIL $TB"; exit 1; }
fi
cp -r "$W/xsim.dir" ./xsim.dir

xelab "$TB" -s snap --debug typical -L work > elaborate.log 2>&1 || {
    echo "ELAB_FAIL $TB"; exit 1; }

timeout 900 xsim snap -runall > console.log 2>&1
echo "SIM_EXIT=$? TB=$TB"
grep -iE 'PASS|FAIL|ERROR|Fatal|Mismatch' console.log | head -8
