# Print every CONFIG property of the RP boundary ports of rm_seg.bd.
source [file join [file dirname [info script]] common.tcl]
open_project $::dfx_work/shell_seg/shell_seg.xpr
open_bd_design [get_files rm_seg.bd]
foreach p {S_AXI_CTRL M_AXI_MEM} {
    set port [get_bd_intf_ports $p]
    foreach prop [lsort [list_property $port CONFIG.*]] {
        puts [format "BOUNDARY %-11s %-32s %s" $p $prop [get_property $prop $port]]
    }
}
close_project
puts "QUERY_DONE"
