# Where is the routing congestion of a placed DFX configuration?
# Usage (tclargs): query_congestion.tcl <placed.dcp> <report.rpt>
lassign $::argv dcp rpt
open_checkpoint $dcp
report_design_analysis -congestion -min_congestion_level 3 -file $rpt
set fh [open $rpt a]
set pins [get_pins -of_objects [get_cells shell_i/rp_accel] -filter {NAME =~ "*S_AXI_CTRL*"}]
puts $fh "\nS_AXI_CTRL partition pins: [llength $pins]"
foreach p [lrange $pins 0 end] {
    puts $fh "PPLOC [get_property REF_PIN_NAME $p] [get_pplocs -pins $p]"
}
set pb [get_pblocks -of_objects [get_cells shell_i/rp_accel]]
puts $fh "\npblock $pb grid [get_property GRID_RANGES $pb]"
close $fh
puts "CONGESTION_DONE $rpt"
