#!/bin/bash
# Server side: recreate the flat project for every RM and summarize the checks.
cd "$(dirname "$0")/../.."
for rm in rm_shape rm_seg; do
    ./run_vivado.sh create_project.tcl "create_$rm" "$rm" > /dev/null 2>&1
    echo "### $rm exit=$?"
    grep -nE '^(ERROR|CRITICAL WARNING)|RTL_OVERRIDE|RP_BOUNDARY|RESET_CHECK|ADDR /ps7_0/Data|ADDR /rp_accel/[a-z_]+/Data|_BD_READY|PROJECT_READY' \
        "logs/create_$rm.log" | head -30
done
echo "### boundary diff"
diff out/boundary_rm_seg.txt out/boundary_rm_shape.txt && echo BOUNDARY_IDENTICAL
