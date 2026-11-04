set here [file dirname [file normalize [info script]]]
set out [file join $here synthesis]
file mkdir $out
set_param general.maxThreads 8
read_verilog -sv [glob $here/rtl/*.sv]
synth_design -top rm_cnn_top -part xc7z020clg400-1 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name ctrl_clk -period 10 [get_ports ctrl_clk]
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/hierarchy.rpt
report_timing_summary -max_paths 20 -file $out/timing.rpt
report_drc -file $out/drc.rpt
# Keep the standalone timing view for review. The integration checkpoint must
# inherit the existing PS FCLK0, including insertion delay and input jitter.
write_checkpoint -force $out/knot_sv_ooc.dcp
if {[get_clocks] ne "ctrl_clk"} {error "Unexpected standalone clock constraints"}
reset_timing
if {[llength [get_clocks -quiet]]} {error "Standalone clock was not cleared"}
write_checkpoint -force $out/knot_sv_synth.dcp
puts SV_KNOT_OOC_DONE
