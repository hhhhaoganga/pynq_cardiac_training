# Site-coordinate extents per clock region and where each static block sits,
# to choose rectangular RP pblock ranges that exclude the static logic.
source [file join [file dirname [info script]] common.tcl]
set_param tcl.collectionResultDisplayLimit 0
open_checkpoint $::dfx_out/$::dfx_proj/${::dfx_proj}_routed.dcp

proc xy {site} {
    regexp {_X(\d+)Y(\d+)$} $site -> x y
    return [list $x $y]
}
foreach cr [lsort [get_clock_regions]] {
    foreach {type pat} {SLICE SLICE_* RAMB36 RAMB36_* DSP48 DSP48_*} {
        set xs {}; set ys {}
        foreach s [get_sites -quiet -of_objects $cr -filter "NAME =~ $pat"] {
            lassign [xy $s] x y
            lappend xs $x; lappend ys $y
        }
        if {![llength $xs]} { continue }
        set cols [lsort -integer -unique $xs]
        puts [format "SITES %-5s %-6s X%d:%d Y%d:%d cols=%s" $cr $type \
            [tcl::mathfunc::min {*}$xs] [tcl::mathfunc::max {*}$xs] \
            [tcl::mathfunc::min {*}$ys] [tcl::mathfunc::max {*}$ys] [join $cols ,]]
    }
}
# Placement extent of each static block (slice coordinates of its leaf cells).
foreach blk {axi_vdma_hdmi v_tc_hdmi v_vid_out_hdmi dvi_tx_hdmi hp0_intercon hp2_intercon gp0_periph sdm_ctrl sdm_mem axi_intc_0 dfx_gpio} {
    set xs {}; set ys {}; set crs {}
    foreach c [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && NAME =~ shell_i/$blk/*"] {
        set loc [get_property LOC $c]
        if {![string match SLICE_* $loc] && ![string match RAMB* $loc]} { continue }
        lassign [xy $loc] x y
        lappend xs $x; lappend ys $y
        lappend crs [get_property CLOCK_REGION [get_sites $loc]]
    }
    if {![llength $xs]} { puts "BLOCK $blk <no slice/bram cells>"; continue }
    puts [format "BLOCK %-15s X%d:%d Y%d:%d regions=%s" $blk \
        [tcl::mathfunc::min {*}$xs] [tcl::mathfunc::max {*}$xs] \
        [tcl::mathfunc::min {*}$ys] [tcl::mathfunc::max {*}$ys] [join [lsort -unique $crs] ,]]
}
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME =~ OSERDES* || REF_NAME =~ BUFG* || REF_NAME =~ MMCM* || REF_NAME =~ BUFIO* || REF_NAME =~ BUFR*}] {
    puts "HARD [get_property REF_NAME $c] [get_property LOC $c] [get_property CLOCK_REGION [get_sites [get_property LOC $c]]]"
}
puts "SITES_DONE"
