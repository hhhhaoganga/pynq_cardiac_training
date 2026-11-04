# Import the new RM into the frozen shell; no placement/routing here.
lassign $argv synth static out
set_param general.maxThreads 8
file mkdir $out
open_checkpoint $static
update_design -cell shell_i/rp_accel -black_box
lock_design -level routing
read_checkpoint -cell shell_i/rp_accel $synth
# An OOC primary clock on the RP port would hide the real PS clock latency
# and jitter. Reject it before creating any physical implementation input.
set rp_clock [get_clocks -of_objects [get_pins shell_i/rp_accel/ctrl_clk]]
set rp_clock_root [all_fanin -flat -startpoints_only -to [get_pins shell_i/rp_accel/ctrl_clk]]
if {$rp_clock ne "clk_fpga_0" || [get_property PERIOD $rp_clock] != 10.0 ||
    $rp_clock_root ne {shell_i/ps7_0/inst/PS7_i/FCLKCLK[0]}} {
    error "RP must inherit 100MHz PS FCLK0; remove standalone OOC clock before import"
}
report_clocks -file $out/integrated_clocks.rpt
set parent [get_pblocks pblock_rp_accel]
if {[llength $parent] != 1} {error "Missing fixed RP boundary"}
set ranges {}
foreach wanted {
    SLICE_X0Y0:SLICE_X81Y49 SLICE_X82Y0:SLICE_X113Y149
    RAMB36_X0Y0:RAMB36_X3Y9 RAMB36_X4Y0:RAMB36_X5Y29
    RAMB18_X0Y0:RAMB18_X3Y19 RAMB18_X4Y0:RAMB18_X5Y59
    DSP48_X0Y0:DSP48_X2Y19 DSP48_X3Y0:DSP48_X4Y59
} {
    regexp {^(\w+)_X(\d+)Y(\d+):\w+_X(\d+)Y(\d+)$} $wanted -> t x0 y0 x1 y1
    foreach p [get_property DERIVED_RANGES $parent] {
        if {![regexp {^(\w+)_X(\d+)Y(\d+):\w+_X(\d+)Y(\d+)$} $p -> pt px0 py0 px1 py1] || $pt ne $t} continue
        set a [expr {max($x0,$px0)}];set b [expr {min($x1,$px1)}]
        set c [expr {max($y0,$py0)}];set d [expr {min($y1,$py1)}]
        if {$a <= $b && $c <= $d} {lappend ranges "${t}_X${a}Y${c}:${t}_X${b}Y${d}"}
    }
}
if {![llength $ranges]} {error "Empty compute region"}
set core [get_cells -quiet shell_i/rp_accel/u_core]
if {[llength $core] != 1} {error "Missing SV core hierarchy"}
# Compute/storage share the connected bottom+right-arm L region; no hard split
# between PW, DW and shared quantization. Exclude the narrow AXI-side left arm.
# AXI/CSR remain free within the original RP. Static logic/routing is unchanged.
set pb [create_pblock pb_sv_compute]
set_property PARENT $parent $pb
resize_pblock $pb -add $ranges
add_cells_to_pblock $pb $core
report_utilization -pblocks $pb -file $out/compute_utilization.rpt
report_utilization -pblocks $parent -file $out/rp_utilization.rpt
report_drc -file $out/drc.rpt
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {error "Preflight DRC failed"}
write_checkpoint -force $out/prepared.dcp
puts SV_KNOT_AUDIT_DONE
