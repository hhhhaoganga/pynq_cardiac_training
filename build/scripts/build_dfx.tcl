# DFX build: impl_1 (static + rm_seg) and child_shape (locked static + rm_shape)
# through write_bitstream, then pr_verify. Outputs in out/shell_dfx:
#   dfx_full_<rm>.bit/.bin      full image (boot with dfx_full_seg)
#   dfx_partial_<rm>.bit/.bin   partial for the rp_accel pblock (fpga_manager takes .bin)
# Gates: setup/hold >= 0 in both runs, no error DRCs, pr_verify passes.
# Usage (tclargs): build_dfx.tcl <base|wide>
set ::rp_rm rm_seg
source [file join [file dirname [info script]] common.tcl]
set_param general.maxThreads 16
set ::dfx_variant [expr {[llength $::argv] ? [lindex $::argv 0] : "base"}]
# Second tclarg "export": skip implementation, re-export the finished runs.
set export_only [expr {[lindex $::argv 1] eq "export"}]
set proj_dir $::dfx_work/shell_dfx_$::dfx_variant
set out $::dfx_out/shell_dfx_$::dfx_variant
file delete -force $out
file mkdir $out
open_project $proj_dir/shell_dfx.xpr
puts "DFX_RUNS [join [get_runs] { }]"

if {!$export_only} {
    reset_run synth_1
    launch_runs impl_1 child_shape -to_step write_bitstream -jobs 32
    wait_on_run impl_1
    wait_on_run child_shape
}
foreach r {impl_1 child_shape} {
    if {![impl_run_ok $r]} { error "$r failed: [get_property STATUS [get_runs $r]]" }
}

# Final full-design checkpoint of a run: post-route phys_opt if it ran, else routed.
# (The run dir also holds RM-only *_rm_*_routed.dcp files; those have no RP instance.)
proc final_dcp {run} {
    set dir [get_property DIRECTORY [get_runs $run]]
    set best ""
    foreach f [list $dir/shell_wrapper_routed.dcp $dir/shell_wrapper_postroute_physopt.dcp] {
        if {[file exists $f] && ($best eq "" || [file mtime $f] >= [file mtime $best])} { set best $f }
    }
    if {$best eq ""} { error "no routed checkpoint in $dir" }
    return $best
}

proc export_dfx_run {run rm out} {
    set dcp [final_dcp $run]
    puts "DFX_DCP $run $dcp"
    open_checkpoint $dcp
    report_timing_summary -max_paths 20 -file $out/timing_$rm.rpt
    report_utilization -file $out/utilization_$rm.rpt
    report_utilization -pblocks [get_pblocks pblock_rp_accel] -file $out/pblock_$rm.rpt
    report_drc -file $out/drc_$rm.rpt
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    set drc_err [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
    puts "DFX_RESULT $rm run=$run WNS=$wns WHS=$whs DRC_ERRORS=$drc_err"
    # Write bitstreams from the exact checkpoint that was checked (.bin for fpga_manager).
    write_bitstream -force -no_partial_bitfile -bin_file $out/dfx_full_$rm.bit
    write_bitstream -force -cell shell_i/rp_accel -bin_file $out/dfx_partial_$rm.bit
    close_design
    foreach f [glob -nocomplain -directory $out dfx_*_$rm.bit dfx_*_$rm.bin] {
        puts "DFX_BITFILE $run [file tail $f] [file size $f]"
    }
    file copy -force $dcp $out/dfx_routed_$rm.dcp
    return [expr {$wns >= 0 && $whs >= 0 && $drc_err == 0}]
}
set ok [export_dfx_run impl_1 seg $out]
set ok [expr {[export_dfx_run child_shape shape $out] && $ok}]
set hwh [lindex [glob -nocomplain $proj_dir/*.gen/sources_1/bd/shell/hw_handoff/shell.hwh] 0]
if {$hwh ne ""} { file copy -force $hwh $out/dfx_static.hwh }
close_project

# Both configurations must share an identical static region.
if {[catch {pr_verify $out/dfx_routed_seg.dcp $out/dfx_routed_shape.dcp -file $out/pr_verify.rpt} err]} {
    puts "PR_VERIFY_FAILED $err"
    set ok 0
} else {
    puts "PR_VERIFY_DONE"
}
if {!$ok} { error "DFX gate failed (see $out reports)" }
puts "SHELL_DFX_BUILD_CHECKED variant=$::dfx_variant"
