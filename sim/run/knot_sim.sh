#!/usr/bin/env bash
K=$(cd "$(dirname "$0")/../knot" 2>/dev/null && pwd)
[ -n "${K:-}" ] && [ -d "$K" ] || { echo "sim/knot not found" >&2; exit 9; }
FIX=$(cd "$(dirname "$0")/../knot_fixture" && pwd)
cd "$K" || exit 1
source ${VIVADO_SETTINGS:-$HOME/Xilinx/Vivado/2024.2/settings64.sh} >/dev/null 2>&1
PB=$(python3 -c "import json;print(json.load(open('$FIX/program.json'))['program_beat'])")

run_one() {
  local name=$1 srcs=$2 top=$3 extra=$4 out=$5
  mkdir -p "$out"
  ( cd "$K" && eval xvlog --sv $srcs > "$out/compile.log" 2>&1
    if [ $? -ne 0 ]; then echo "COMPILE_FAIL $name"; return; fi
    eval xelab $top -s ${name}_snap --debug typical --mt 8 > "$out/elaborate.log" 2>&1
    if [ $? -ne 0 ]; then echo "ELAB_FAIL $name"; return; fi
    eval xsim ${name}_snap -runall -testplusarg PROGRAM=$PB $extra > "$out/console.log" 2>&1
    echo "RUN_DONE $name"
    grep -E "PASS|FAIL" "$out/console.log" | head -5 )
}

run_one knot   "*.sv tb/tb_knot.sv"       tb_knot   "-testplusarg STALL=0" "$K/out_knot" &
run_one knotaxi "*.sv tb/tb_axi.sv"       tb_axi    "-testplusarg STALL=1" "$K/out_knotaxi" &
run_one quant  "knot_quant8.sv tb/tb_quant.sv" tb_quant "" "$K/out_quant" &
wait
