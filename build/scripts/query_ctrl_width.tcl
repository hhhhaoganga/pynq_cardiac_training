# Where does the rp_accel S_AXI_CTRL width come from? Reports ADDR_WIDTH on
# every AXI-Lite pin along the control path in shell.bd and both RM BDs.
source [file join [file dirname [info script]] common.tcl]
open_project $::dfx_work/shell_dfx_wide/shell_dfx.xpr
proc rep {what objs} {
    foreach o $objs {
        puts "CTRLW $what $o ADDR_WIDTH=[get_property -quiet CONFIG.ADDR_WIDTH $o] src=[get_property -quiet CONFIG.ADDR_WIDTH.VALUE_SRC $o]"
    }
}
foreach rm {rm_seg rm_shape} {
    open_bd_design [get_files $rm.bd]
    rep $rm [get_bd_intf_ports S_AXI_CTRL]
    rep $rm [get_bd_intf_pins -hier -filter {MODE == Slave && VLNV =~ "*aximm*"}]
    foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces S_AXI_CTRL]] {
        puts "CTRLW $rm seg $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
    }
    close_bd_design [current_bd_design]
}
open_bd_design [get_files shell.bd]
rep shell [get_bd_intf_pins {rp_accel/S_AXI_CTRL sdm_ctrl/M_AXI sdm_ctrl/S_AXI}]
foreach s [get_bd_addr_segs -of_objects [get_bd_intf_pins rp_accel/S_AXI_CTRL]] {
    puts "CTRLW shell seg $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
}
foreach s [get_bd_addr_segs -filter {NAME =~ "*rp_accel*" || PATH =~ "*rp_accel*"}] {
    puts "CTRLW shell aseg $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
}
puts "CTRLW_DONE"
