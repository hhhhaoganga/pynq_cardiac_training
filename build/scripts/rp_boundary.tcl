# Frozen boundary of the reconfigurable accelerator slot. Every RM block
# design calls create_rp_boundary; changing it invalidates the static shell
# and every partial bitstream built against it.
#
#   S_AXI_CTRL  AXI4-Lite slave, ctrl_clk (100 MHz). The GP0 map gives the slot
#               0x4000_0000-0x400F_FFFF, but only address [7:0] crosses the
#               boundary: the generated container port takes the width of the
#               active RM's endpoint (camus_stream_rtl, 8 bits), and widening
#               it re-places the static shell. Each RM has one control endpoint
#               at the slot base (::rp_ctrl_map); RMs with two slaves put
#               rp_ctrl_split behind it (0x00-0x7F / 0x80-0xFF).
#   M_AXI_MEM   AXI4 master, 32-bit address, 64-bit data, 6-bit ID, no
#               USER/LOCK/REGION, ctrl_clk (100 MHz) -> HP2. Every RM drives
#               it through rp_mem_adapter so the port set is identical.
#               One bus clock for both interfaces: a separate 142.857 MHz
#               memory clock cost six AXI clock converters (~970 slices) in
#               rm_seg; HP2 itself accepts 100 MHz (its FIFO is async).
#   fast_clk    200 MHz, reserved for RMs that need a faster compute clock
#   *_resetn    active-low, synchronous to the matching clock, asserted while the RP is held
#   irq         level-high interrupt -> axi_intc input 0
set ::rp_ctrl_base 0x40000000
set ::rp_ctrl_span 1M
# Address bits of S_AXI_CTRL that cross the boundary (checked in create_dfx).
set ::rp_ctrl_addr_w 8
# RM -> {cell slot ...}; the slave on <cell> sits at rp_ctrl_base + slot*64 KiB.
set ::rp_ctrl_map {
    rm_seg   {camus_stream_rtl 0}
    rm_shape {rp_ctrl_split_0 0}
}

# 1:2 control split for RMs with two register slaves: <m00> gets 0x00-0x7F,
# <m01> 0x80-0xFF of the slot. Each slave is mapped at 0 of its split master.
proc add_rp_ctrl_split {m00 m01} {
    create_bd_cell -type module -reference rp_ctrl_split rp_ctrl_split_0
    connect_bd_intf_net [get_bd_intf_ports S_AXI_CTRL] [get_bd_intf_pins rp_ctrl_split_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins rp_ctrl_split_0/m00_axi] [get_bd_intf_pins $m00]
    connect_bd_intf_net [get_bd_intf_pins rp_ctrl_split_0/m01_axi] [get_bd_intf_pins $m01]
    connect_bd_net [get_bd_ports ctrl_clk] [get_bd_pins rp_ctrl_split_0/aclk]
    connect_bd_net [get_bd_ports ctrl_resetn] [get_bd_pins rp_ctrl_split_0/aresetn]
}

proc assign_rp_ctrl_split {m00 m01} {
    foreach {m s} [list m00_axi $m00 m01_axi $m01] {
        assign_bd_address -offset 0x00000000 -range 64K \
            -target_address_space [get_bd_addr_spaces rp_ctrl_split_0/$m] \
            [get_bd_addr_segs -of_objects [get_bd_intf_pins $s]] -force
    }
}

proc create_rp_boundary {} {
    set ctrl [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_CTRL]
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.ADDR_WIDTH 32 \
        CONFIG.DATA_WIDTH 32 CONFIG.FREQ_HZ $::fclk0_hz] $ctrl

    set mem [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_MEM]
    # Widths/ID come from rp_mem_adapter; check_rp_boundary enforces them.
    set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.ADDR_WIDTH 32 \
        CONFIG.DATA_WIDTH 64 CONFIG.FREQ_HZ $::fclk0_hz] $mem

    create_bd_port -dir I -type clk -freq_hz $::fclk0_hz ctrl_clk
    create_bd_port -dir I -type clk -freq_hz $::fclk2_hz fast_clk
    foreach r {ctrl_resetn fast_resetn} {
        create_bd_port -dir I -type rst $r
        set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports $r]
    }
    create_bd_port -dir O -type intr irq

    set_property -dict [list CONFIG.ASSOCIATED_BUSIF S_AXI_CTRL:M_AXI_MEM CONFIG.ASSOCIATED_RESET ctrl_resetn] [get_bd_ports ctrl_clk]
    set_property CONFIG.ASSOCIATED_RESET fast_resetn [get_bd_ports fast_clk]
}

# Instantiate the boundary adapter between the RM's memory interconnect
# master (<ic_master>, clocked by ctrl_clk) and M_AXI_MEM.
proc add_rp_mem_adapter {ic_master s_id_w} {
    set a [create_bd_cell -type module -reference rp_mem_adapter rp_mem_adapter_0]
    set_property CONFIG.S_ID_W $s_id_w $a
    connect_bd_intf_net [get_bd_intf_pins $ic_master] [get_bd_intf_pins rp_mem_adapter_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins rp_mem_adapter_0/m_axi] [get_bd_intf_ports M_AXI_MEM]
    connect_bd_net [get_bd_ports ctrl_clk] [get_bd_pins rp_mem_adapter_0/aclk]
    connect_bd_net [get_bd_ports ctrl_resetn] [get_bd_pins rp_mem_adapter_0/aresetn]
}

# A module reference is an address endpoint to IP integrator, not a bridge, so
# map DDR in two identity hops: every RM master sees the adapter at 0..512M,
# and the adapter sees M_AXI_MEM at 0..512M. Addresses pass through unchanged.
proc assign_rp_mem {spaces} {
    set adapter_seg [get_bd_addr_segs rp_mem_adapter_0/s_axi/reg0]
    foreach space $spaces {
        assign_bd_address -offset 0x00000000 -range 512M \
            -target_address_space [get_bd_addr_spaces $space] $adapter_seg -force
    }
    assign_bd_address -offset 0x00000000 -range 512M \
        -target_address_space [get_bd_addr_spaces rp_mem_adapter_0/m_axi] \
        [get_bd_addr_segs M_AXI_MEM/Reg] -force
}

# ID width actually driven on an AXI interface pin (0 if it has no ID signals).
proc intf_id_width {intf} {
    set p [get_bd_pins -quiet -of_objects [get_bd_intf_pins $intf] -filter {NAME =~ "*_awid"}]
    if {![llength $p]} { return 0 }
    return [expr {abs([get_property LEFT $p] - [get_property RIGHT $p]) + 1}]
}

# Validate, then size the adapter's RM side to the interconnect's real ID width.
proc fit_rp_mem_adapter {ic_master} {
    validate_bd_design
    set w [expr {max([intf_id_width $ic_master], 1)}]
    if {$w != [get_property CONFIG.S_ID_W [get_bd_cells rp_mem_adapter_0]]} {
        puts "RP_BOUNDARY resizing rp_mem_adapter S_ID_W to $w"
        set_property CONFIG.S_ID_W $w [get_bd_cells rp_mem_adapter_0]
        validate_bd_design
    }
}

# Place this RM's control slaves per ::rp_ctrl_map (inside the RM block design).
proc assign_rm_ctrl {rm} {
    set space [get_bd_addr_spaces S_AXI_CTRL]
    foreach {cell slot} [dict get $::rp_ctrl_map $rm] {
        set seg [get_bd_addr_segs -of_objects [get_bd_intf_pins -of_objects [get_bd_cells $cell] -filter {MODE == Slave && VLNV =~ "*aximm*"}]]
        assign_bd_address -offset [format 0x%08X [expr {$::rp_ctrl_base + $slot * 0x10000}]] \
            -range 64K -target_address_space $space $seg -force
    }
}

# Call after validate_bd_design. The adapter's RM side must match the RM
# interconnect, and the frozen side must be exactly what the static shell expects.
proc check_rp_boundary {ic_master} {
    set ic_id [expr {max([intf_id_width $ic_master], 1)}]
    set s_id [get_property CONFIG.S_ID_W [get_bd_cells rp_mem_adapter_0]]
    set mem [get_bd_intf_ports M_AXI_MEM]
    set got [list [get_property CONFIG.ID_WIDTH $mem] [get_property CONFIG.DATA_WIDTH $mem] \
        [get_property CONFIG.ADDR_WIDTH $mem] [get_property CONFIG.AWUSER_WIDTH $mem] \
        [get_property CONFIG.HAS_LOCK $mem] [get_property CONFIG.HAS_REGION $mem]]
    puts "RP_BOUNDARY ic_id=$ic_id adapter_s_id=$s_id M_AXI_MEM id/data/addr/awuser/lock/region=$got"
    if {$ic_id != $s_id} { error "RM interconnect ID width $ic_id != rp_mem_adapter S_ID_W $s_id" }
    if {$got ne {6 64 32 0 0 0}} { error "M_AXI_MEM boundary is $got, expected {6 64 32 0 0 0}" }
}

# Record every boundary property so RMs can be diffed before enabling DFX.
proc dump_rp_boundary {file} {
    set fh [open $file w]
    foreach p {S_AXI_CTRL M_AXI_MEM} {
        set port [get_bd_intf_ports $p]
        foreach prop [lsort [list_property $port CONFIG.*]] {
            if {$prop in {CONFIG.CLK_DOMAIN}} { continue }
            puts $fh "$p $prop [get_property $prop $port]"
        }
    }
    close $fh
}
