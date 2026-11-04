#!/bin/bash
# Server side: for each RP pblock variant given (default: base wide), create
# the DFX project and build both configurations + pr_verify, all variants in
# parallel. Summarizes the gate results per variant.
cd "$(dirname "$0")/../.."
variants=${*:-base wide}

one() {
    v=$1
    ./run_vivado.sh create_dfx.tcl "create_dfx_$v" "$v" > /dev/null 2>&1
    echo "CREATE exit=$?"
    ./run_vivado.sh build_dfx.tcl "build_dfx_$v" "$v" > /dev/null 2>&1
    echo "BUILD exit=$?"
}
pids=()
for v in $variants; do
    one "$v" > "logs/dfx_$v.status" 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

for v in $variants; do
    echo "######## variant $v"
    cat "logs/dfx_$v.status"
    grep -E '^(ERROR|CRITICAL WARNING)|DFX_VARIANT|DFX_SHAPE_REPO|RP_BOUNDARY|RESET_CHECK|DFX_PROJECT_READY' "logs/create_dfx_$v.log" | head -12
    grep -E '^(ERROR|CRITICAL WARNING)|DFX_RESULT|DFX_BITFILE|PR_VERIFY|SHELL_DFX_BUILD_CHECKED|gate failed' "logs/build_dfx_$v.log" | head -30
    o=out/shell_dfx_$v
    for rm in seg shape; do
        f=$o/pblock_$rm.rpt
        [ -f "$f" ] && { echo "== pblock $rm"; grep -E '^\| (Slice LUTs|Slice  |Block RAM Tile|DSPs) ' "$f" | head -4; }
    done
    [ -f "$o/pr_verify.rpt" ] && grep -iE 'result|compatible|ERROR' "$o/pr_verify.rpt" | head -5
    (cd "$o" 2>/dev/null && sha256sum dfx_full_*.bit dfx_partial_*.bin 2>/dev/null)
done
echo DFX_ALL_DONE
