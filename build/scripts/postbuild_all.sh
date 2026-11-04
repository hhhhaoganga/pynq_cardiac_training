#!/bin/bash
# Server side: post-build checks for every RM (reset wiring, utilization, worst path).
cd "$(dirname "$0")/../.."
for rm in rm_shape rm_seg; do
    proj=shell_${rm#rm_}
    echo "### $proj"
    ./run_vivado.sh check_reset_netlist.tcl "reset_$proj" "$rm" > /dev/null 2>&1
    grep -E '^NET .*(aux_reset_in|ext_reset_in)' "logs/reset_$proj.log"
    grep -E '^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs) ' "out/$proj/utilization.rpt" | head -4
    grep -m1 -E '^Slack' "out/$proj/timing.rpt"
    grep -m3 -E '^  (Source|Destination|Path Group):' "out/$proj/timing.rpt"
    grep -cE '^\| \S+ +\| Error +\|' "out/$proj/drc.rpt" | sed 's/^/drc_error_rules=/'
    grep -E '^(Critical|Warning|Info) ' "out/$proj/cdc.rpt" | awk '{print "cdc "$1" unsafe="$(NF-2)}' | sort | uniq -c
done
