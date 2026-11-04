# Geometry of the static strip X0Y1+X0Y2 (beside the PS7) and actual static
# slice usage in the placed DFX parent, to size a larger RP pblock.
source [file join [file dirname [info script]] common.tcl]
set_param tcl.collectionResultDisplayLimit 0
open_checkpoint $::dfx_work/shell_dfx/shell_dfx.runs/impl_1/shell_wrapper_placed.dcp

proc gx {site} { get_property GRID_POINT_X [get_tiles -of_objects [get_sites $site]] }
set cols {}
for {set x 26} {$x <= 49} {incr x} { lappend cols "S$x=[gx SLICE_X${x}Y100]" }
puts "GRID slices [join $cols { }]"
puts "GRID RAMB36_X2Y20=[gx RAMB36_X2Y20] DSP48_X2Y40=[gx DSP48_X2Y40] SLICE_X50Y100=[gx SLICE_X50Y100]"

# Static (non-RP) occupied slices, overall and by block, plus per-column fill.
set used {}
set byblk {}
foreach c [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE && NAME !~ "shell_i/rp_accel/*"}] {
    set loc [get_property LOC $c]
    if {![string match SLICE_* $loc]} { continue }
    dict set used $loc 1
    set blk [lindex [split [get_property NAME $c] /] 1]
    dict set byblk $blk $loc 1
}
puts "STATIC_SLICES total=[dict size $used]"
dict for {blk locs} $byblk { puts [format "STATIC_BLK %-18s slices=%d" $blk [dict size $locs]] }
foreach x {26 30 34 38 40 42 44 46 48 49} {
    set n 0
    dict for {loc v} $used { if {[regexp "^SLICE_X${x}Y" $loc]} { incr n } }
    puts "STATIC_COL X$x used=$n"
}
puts "GEOM_DONE"
