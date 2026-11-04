# Why is the RP pblock 99% slice-full at 76% LUT? Control sets and per-module
# slice usage of the placed DFX parent (impl_1) checkpoint.
source [file join [file dirname [info script]] common.tcl]
set_param tcl.collectionResultDisplayLimit 0
set dcp $::dfx_work/shell_dfx/shell_dfx.runs/impl_1/shell_wrapper_placed.dcp
open_checkpoint $dcp
set out $::dfx_out/shell_dfx_analysis
file mkdir $out
report_control_sets -hierarchical -hierarchical_depth 6 -file $out/control_sets.rpt
report_control_sets -verbose -file $out/control_sets_summary.rpt
# Slices occupied per RP sub-module (a slice counts once for the module owning its cells).
set rp shell_i/rp_accel
foreach m [get_cells -quiet $rp/* -filter {!IS_PRIMITIVE}] {
    set cells [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && NAME =~ [get_property NAME $m]/*"]
    set sl {}
    foreach c $cells {
        set loc [get_property LOC $c]
        if {[string match SLICE_* $loc]} { lappend sl $loc }
    }
    set luts [llength [get_cells -quiet -hierarchical -filter "PRIMITIVE_GROUP == LUT && NAME =~ [get_property NAME $m]/*"]]
    set ffs [llength [get_cells -quiet -hierarchical -filter "PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ [get_property NAME $m]/*"]]
    puts [format "RPMOD %-40s slices=%5d luts=%6d ffs=%6d" [file tail $m] [llength [lsort -unique $sl]] $luts $ffs]
}
set core $rp/camus_stream_rtl/inst/u_impl/u_core/u_core
foreach m [get_cells -quiet $core/* -filter {!IS_PRIMITIVE}] {
    set name [get_property NAME $m]
    set sl {}
    foreach c [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && NAME =~ $name/*"] {
        set loc [get_property LOC $c]
        if {[string match SLICE_* $loc]} { lappend sl $loc }
    }
    puts [format "COREMOD %-40s slices=%5d" [file tail $m] [llength [lsort -unique $sl]]]
}
puts "ANALYZE_DONE"
