#!/bin/bash
# Server side: synth + strategy sweep for every RM in parallel, then summarize.
cd "$(dirname "$0")/../.."
pids=()
for rm in rm_shape rm_seg; do
    ./run_vivado.sh sweep_impl.tcl "sweep_$rm" "$rm" > "logs/sweep_$rm.out" 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for rm in rm_shape rm_seg; do
    echo "### $rm"
    grep -nE '^(ERROR|CRITICAL WARNING)|^SWEEP|BUILD_RESULT|_BUILD_CHECKED|gate failed' "logs/sweep_$rm.log" | head -20
    proj=shell_${rm#rm_}
    (cd "out/$proj" 2>/dev/null && sha256sum "$proj"*.bit "$proj"*.hwh 2>/dev/null)
done
echo SWEEP_ALL_DONE
