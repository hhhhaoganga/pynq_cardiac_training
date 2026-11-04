# Print configurable parameters of the IPs used by the static shell.
create_project -in_memory -part xc7z020clg400-1
create_bd_design probe
foreach {name vlnv} {
    sdm   xilinx.com:ip:dfx_axi_shutdown_manager:*
    dec   xilinx.com:ip:dfx_decoupler:*
    vdma  xilinx.com:ip:axi_vdma:*
    vtc   xilinx.com:ip:v_tc:*
    sub   xilinx.com:ip:axis_subset_converter:*
    intc  xilinx.com:ip:axi_intc:*
    gpio  xilinx.com:ip:axi_gpio:*
    rst   xilinx.com:ip:proc_sys_reset:*
} {
    set def [lindex [get_ipdefs -all $vlnv] end]
    puts "=== $name $def"
    if {$def eq ""} { continue }
    if {[catch {create_bd_cell -type ip -vlnv $def $name} err]} { puts "ERR $err"; continue }
    set props [lsort [list_property [get_bd_cells $name] CONFIG.*]]
    if {$name in {vdma}} {
        set props [lsearch -all -inline -regexp $props {include|fstores|data_width|burst|linebuffer|flush|genlock|fsync|use_fsync|addr_width|enable_vert}]
    }
    foreach p $props { puts "  $p = [get_property $p [get_bd_cells $name]]" }
    foreach pin [get_bd_intf_pins -of [get_bd_cells $name]] { puts "  intf [file tail $pin] [get_property MODE $pin]" }
    foreach pin [get_bd_pins -of [get_bd_cells $name]] { puts "  pin [file tail $pin] [get_property DIR $pin] [get_property LEFT $pin]" }
}
puts "PROBE_DONE"
