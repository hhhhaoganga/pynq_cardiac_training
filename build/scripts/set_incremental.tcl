# Point an existing DFX project's impl runs at a known-good routed checkpoint
# (incremental implementation), so a small static change (e.g. UART1 EMIO)
# reuses the old placement instead of re-placing rm_seg into congestion.
# Usage (tclargs): set_incremental.tcl <variant> <ref_runs_dir> [physopt|routed]
#   ref_runs_dir = .../work/shell_dfx_wide/shell_dfx.runs of a passing build
set ::rp_rm rm_seg
source [file join [file dirname [info script]] common.tcl]
set variant [lindex $::argv 0]
set ref [lindex $::argv 1]
set kind [expr {[llength $::argv] > 2 ? [lindex $::argv 2] : "physopt"}]
set dcp_name [dict get {physopt shell_wrapper_postroute_physopt.dcp routed shell_wrapper_routed.dcp} $kind]
open_project $::dfx_work/shell_dfx_$variant/shell_dfx.xpr
# Only the parent run: child_shape imports the locked static from impl_1.
foreach {run refrun} {impl_1 impl_1} {
    set dcp $ref/$refrun/$dcp_name
    if {![file exists $dcp]} { set dcp $ref/$refrun/shell_wrapper_routed.dcp }
    if {![file exists $dcp]} { error "no reference checkpoint for $run in $ref/$refrun" }
    set_property INCREMENTAL_CHECKPOINT $dcp [get_runs $run]
    puts "DFX_INCREMENTAL $run [get_property INCREMENTAL_CHECKPOINT [get_runs $run]]"
}
close_project
