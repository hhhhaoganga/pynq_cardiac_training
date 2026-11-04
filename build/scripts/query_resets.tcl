# Print reset polarity and DFX-control configuration of the built shell.
source [file join [file dirname [info script]] common.tcl]
open_project $::dfx_work/shell_seg/shell_seg.xpr
open_bd_design [get_files shell.bd]
foreach cell [get_bd_cells -filter {VLNV =~ "*proc_sys_reset*"}] {
    puts [format "%-14s EXT_HIGH=%s AUX_HIGH=%s" [file tail $cell] \
        [get_property CONFIG.C_EXT_RESET_HIGH $cell] [get_property CONFIG.C_AUX_RESET_HIGH $cell]]
}
foreach cell {sdm_ctrl sdm_mem} {
    set c [get_bd_cells $cell]
    puts "$cell: [join [lmap p {DP_PROTOCOL RP_IS_MASTER CTRL_INTERFACE_TYPE RESET_ACTIVE_LEVEL DP_AXI_ID_WIDTH DP_AXI_ADDR_WIDTH} {format %s=%s $p [get_property CONFIG.$p $c]}] { }]"
}
set g [get_bd_cells dfx_gpio]
puts "dfx_gpio: [join [lmap p {C_IS_DUAL C_GPIO_WIDTH C_ALL_OUTPUTS C_DOUT_DEFAULT C_GPIO2_WIDTH C_ALL_INPUTS_2} {format %s=%s $p [get_property CONFIG.$p $g]}] { }]"
foreach pin {rst_rp_ctrl/aux_reset_in rst_rp_mem/aux_reset_in rst_ps_100/ext_reset_in sdm_ctrl/resetn sdm_ctrl/request_shutdown} {
    set p [get_bd_pins $pin]
    puts [format "PIN %-28s TYPE=%s POLARITY=%s net=%s" $pin [get_property TYPE $p] \
        [get_property CONFIG.POLARITY $p] [get_bd_nets -of_objects $p]]
}
close_project
puts "QUERY_DONE"
