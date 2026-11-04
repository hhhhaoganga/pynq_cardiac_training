# Device floorplan facts for sizing the RP pblock: resources per clock
# region, where the static logic sits in the routed flat design, IO regions.
source [file join [file dirname [info script]] common.tcl]
set_param tcl.collectionResultDisplayLimit 0
open_checkpoint $::dfx_out/$::dfx_proj/${::dfx_proj}_routed.dcp
foreach cr [lsort [get_clock_regions]] {
    set slices [llength [get_sites -quiet -of_objects $cr -filter {NAME =~ SLICE_*}]]
    set b36 [llength [get_sites -quiet -of_objects $cr -filter {NAME =~ RAMB36_*}]]
    set dsp [llength [get_sites -quiet -of_objects $cr -filter {NAME =~ DSP48_*}]]
    set used_b36 [llength [get_cells -quiet -hierarchical -filter "PRIMITIVE_GROUP == BLOCKRAM && LOC =~ RAMB36_* && NAME !~ shell_i/rp_accel/*" ]]
    puts [format "CR %-5s slices=%5d luts=%6d bram36=%3d dsp=%3d" $cr $slices [expr {$slices*4}] $b36 $dsp]
}
foreach p [lsort [get_ports TMDS_0_*]] {
    set site [get_sites -quiet -of_objects $p]
    puts "PORT [get_property NAME $p] site=$site cr=[get_property CLOCK_REGION $site]"
}
# Static (non-RP) placed leaf cells per clock region, split by resource type.
set counts {}
foreach c [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE && NAME !~ "shell_i/rp_accel/*"}] {
    set loc [get_property LOC $c]
    if {$loc eq ""} { continue }
    set cr [get_property CLOCK_REGION [get_sites $loc]]
    set grp [get_property PRIMITIVE_GROUP $c]
    dict incr counts "$cr $grp"
}
foreach k [lsort [dict keys $counts]] { puts "STATIC $k [dict get $counts $k]" }
set ps [get_cells -hierarchical -filter {REF_NAME == PS7}]
puts "PS7 site=[get_property LOC $ps] cr=[get_property CLOCK_REGION [get_sites [get_property LOC $ps]]]"
puts "FLOORPLAN_DONE"
