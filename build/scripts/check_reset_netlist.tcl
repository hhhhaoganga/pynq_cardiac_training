# Verify in the routed design that no proc_sys_reset is held in reset by a
# tied-off input: prints the driver of every reset-related pin.
source [file join [file dirname [info script]] common.tcl]
open_checkpoint $::dfx_out/$::dfx_proj/${::dfx_proj}_routed.dcp
foreach r {rst_ps_100 rst_ps_142 rst_rp_ctrl rst_rp_mem rst_rp_fast} {
    foreach pin {ext_reset_in aux_reset_in dcm_locked mb_debug_sys_rst} {
        set p [get_pins -quiet shell_i/$r/$pin]
        if {![llength $p]} { puts [format "NET %-12s %-18s <no pin>" $r $pin]; continue }
        set n [get_nets -quiet -of_objects $p]
        set type [expr {[llength $n] ? [get_property TYPE $n] : "none"}]
        set drv [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]
        puts [format "NET %-12s %-18s type=%-8s driver=%s" $r $pin $type [lindex $drv 0]]
    }
}
puts "RESET_NETLIST_DONE"
