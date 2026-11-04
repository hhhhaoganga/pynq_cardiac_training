# Resource / power / clock reports of the deployed DFX configurations (routed full designs).
#   vivado -mode batch -source vivado_reports.tcl -tclargs <out_dir> <dcp> <tag> [<dcp> <tag> ...]
set out [lindex $argv 0]
file mkdir $out
foreach {dcp tag} [lrange $argv 1 end] {
    open_checkpoint $dcp
    report_utilization -file $out/util_${tag}.rpt
    report_utilization -hierarchical -hierarchical_depth 4 -file $out/util_hier_${tag}.rpt
    report_clocks -file $out/clocks_${tag}.rpt
    report_clock_utilization -file $out/clock_util_${tag}.rpt
    report_timing_summary -max_paths 5 -file $out/timing_${tag}.rpt
    # Vectorless estimate (default 12.5 % toggle, 0.5 static probability); no simulation activity.
    report_power -file $out/power_${tag}.rpt
    report_power -hier all -hierarchical_depth 4 -file $out/power_hier_${tag}.rpt
    close_design
}
puts VIVADO_REPORTS_DONE
