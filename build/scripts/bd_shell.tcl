# Static shell for PYNQ-Z2 (shell.bd): PS7 (official PYNQ v3.1 Z2 preset),
# 720p HDMI out (VDMA XRGB8888 x3 -> RGB888 -> vid_out -> DVI), axi_intc,
# DFX GPIO + shutdown managers, and the rp_accel slot (block design container).
#
# GP0 map: 0x4000_0000-0x400F_FFFF rp_accel (64 KiB slots, rp_ctrl_map)
#          0x4120_0000 dfx_gpio | 0x4180_0000 axi_intc | 0x4300_0000 VDMA
# 720p timing comes from the fixed vtg_720p (no AXI registers; replaces v_tc).
# HP0: VDMA read (142.857 MHz).  HP2: rp_accel memory master (100 MHz, the RP
# bus clock).  IRQ_F2P[0] <- axi_intc
# axi_intc inputs: [0] rp_accel irq, [1] VDMA mm2s_introut
# PS UART1 via EMIO -> Pmod JB (W14 rxd, Y14 txd) for the JY62 IMU.
source [file join [file dirname [info script]] common.tcl]
source [file join [file dirname [info script]] rp_boundary.tcl]

create_bd_design shell

# --- PS7 --------------------------------------------------------------------
source $::dfx_ref/ps7_block.tcl
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP1 {0} CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_USE_S_AXI_HP2 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} CONFIG.PCW_UART1_UART1_IO {EMIO} \
    CONFIG.PCW_UART1_BAUD_RATE {115200}] $ps7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} $ps7_0
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 UART_1
connect_bd_intf_net [get_bd_intf_pins ps7_0/UART_1] [get_bd_intf_ports UART_1]

# --- resets -----------------------------------------------------------------
foreach r {rst_ps_100 rst_ps_142 rst_rp_ctrl rst_rp_fast} {
    bd_ip xilinx.com:ip:proc_sys_reset:* $r
}

# --- HDMI output path -------------------------------------------------------
bd_ip xilinx.com:ip:clk_wiz:* clk_wiz_hdmi [list \
    CONFIG.PRIM_SOURCE {No_buffer} CONFIG.USE_PHASE_ALIGNMENT {false} \
    CONFIG.CLKOUT2_USED {true} CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.25} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {371.25} \
    CONFIG.CLKOUT1_DRIVES {BUFG} CONFIG.CLKOUT2_DRIVES {No_buffer}]
create_bd_cell -type module -reference vtg_720p vtg_hdmi
bd_ip xilinx.com:ip:axi_vdma:* axi_vdma_hdmi [list \
    CONFIG.c_include_s2mm {0} CONFIG.c_include_mm2s {1} CONFIG.c_num_fstores {3} \
    CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_linebuffer_depth {2048} CONFIG.c_mm2s_max_burst_length {64} \
    CONFIG.c_mm2s_genlock_mode {0}]
bd_ip xilinx.com:ip:axis_subset_converter:* xrgb_to_rgb [list \
    CONFIG.S_TDATA_NUM_BYTES {4} CONFIG.S_HAS_TLAST {1} CONFIG.S_HAS_TKEEP {1} \
    CONFIG.S_TUSER_WIDTH {1} \
    CONFIG.M_TDATA_NUM_BYTES {3} CONFIG.TDATA_REMAP {tdata[23:0]} \
    CONFIG.M_HAS_TLAST {1} CONFIG.TLAST_REMAP {tlast[0]} \
    CONFIG.M_TUSER_WIDTH {1} CONFIG.TUSER_REMAP {tuser[0:0]}]
bd_ip xilinx.com:ip:v_axi4s_vid_out:* v_vid_out_hdmi [list CONFIG.C_HAS_ASYNC_CLK {1}]
create_bd_cell -type ip -vlnv [pick_vlnv minstru.com:user:dvi_transmitter:*] dvi_tx_hdmi
create_bd_intf_port -mode Master -vlnv [get_property VLNV [get_bd_intf_pins dvi_tx_hdmi/TMDS]] TMDS_0

# --- interconnect, interrupts, DFX control ---------------------------------
bd_ip xilinx.com:ip:axi_interconnect:* gp0_periph [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4}]
bd_ip xilinx.com:ip:axi_interconnect:* hp0_intercon [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}]
bd_ip xilinx.com:ip:axi_interconnect:* hp2_intercon [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}]
bd_ip xilinx.com:ip:xlconcat:* irq_concat [list CONFIG.NUM_PORTS {2}]
bd_ip xilinx.com:ip:axi_intc:* axi_intc_0
bd_ip xilinx.com:ip:axi_gpio:* dfx_gpio [list CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {2} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_GPIO2_WIDTH {2} CONFIG.C_ALL_INPUTS_2 {1}]
create_bd_cell -type module -reference dfx_ctrl_sync dfx_sync
bd_ip xilinx.com:ip:dfx_axi_shutdown_manager:* sdm_ctrl [list CONFIG.DP_PROTOCOL {AXI4LITE} \
    CONFIG.RP_IS_MASTER {false} CONFIG.DP_AXI_ADDR_WIDTH {32} CONFIG.DP_AXI_DATA_WIDTH {32}]
bd_ip xilinx.com:ip:dfx_axi_shutdown_manager:* sdm_mem [list CONFIG.DP_PROTOCOL {AXI4MM} \
    CONFIG.RP_IS_MASTER {true} CONFIG.DP_AXI_ADDR_WIDTH {32} CONFIG.DP_AXI_DATA_WIDTH {64} \
    CONFIG.DP_AXI_ID_WIDTH {6}]

# --- reconfigurable slot ----------------------------------------------------
create_bd_cell -type container -reference $::rp_rm rp_accel
set_property -dict [list CONFIG.ACTIVE_SIM_BD $::rp_rm.bd CONFIG.ACTIVE_SYNTH_BD $::rp_rm.bd] [get_bd_cells rp_accel]

# --- interface connections --------------------------------------------------
bd_link ps7_0/M_AXI_GP0 gp0_periph/S00_AXI
bd_link gp0_periph/M00_AXI sdm_ctrl/S_AXI
bd_link sdm_ctrl/M_AXI rp_accel/S_AXI_CTRL
bd_link gp0_periph/M01_AXI dfx_gpio/S_AXI
bd_link gp0_periph/M02_AXI axi_intc_0/s_axi
bd_link gp0_periph/M03_AXI axi_vdma_hdmi/S_AXI_LITE
bd_link rp_accel/M_AXI_MEM sdm_mem/S_AXI
bd_link sdm_mem/M_AXI hp2_intercon/S00_AXI
bd_link hp2_intercon/M00_AXI ps7_0/S_AXI_HP2
bd_link axi_vdma_hdmi/M_AXI_MM2S hp0_intercon/S00_AXI
bd_link hp0_intercon/M00_AXI ps7_0/S_AXI_HP0
bd_link axi_vdma_hdmi/M_AXIS_MM2S xrgb_to_rgb/S_AXIS
bd_link xrgb_to_rgb/M_AXIS v_vid_out_hdmi/video_in
bd_link vtg_hdmi/vtiming_out v_vid_out_hdmi/vtiming_in
bd_link v_vid_out_hdmi/vid_io_out dvi_tx_hdmi/Video_In
bd_link dvi_tx_hdmi/TMDS TMDS_0

# --- clocks -----------------------------------------------------------------
bd_net ps7_0/FCLK_CLK0 ps7_0/M_AXI_GP0_ACLK ps7_0/S_AXI_HP2_ACLK \
    rst_ps_100/slowest_sync_clk rst_rp_ctrl/slowest_sync_clk \
    gp0_periph/ACLK gp0_periph/S00_ACLK gp0_periph/M00_ACLK gp0_periph/M01_ACLK \
    gp0_periph/M02_ACLK gp0_periph/M03_ACLK \
    hp2_intercon/ACLK hp2_intercon/S00_ACLK hp2_intercon/M00_ACLK \
    sdm_ctrl/clk sdm_mem/clk dfx_gpio/s_axi_aclk axi_intc_0/s_axi_aclk axi_vdma_hdmi/s_axi_lite_aclk \
    clk_wiz_hdmi/clk_in1 dfx_sync/ctrl_clk rp_accel/ctrl_clk
bd_net ps7_0/FCLK_CLK1 ps7_0/S_AXI_HP0_ACLK rst_ps_142/slowest_sync_clk \
    hp0_intercon/ACLK hp0_intercon/S00_ACLK hp0_intercon/M00_ACLK \
    axi_vdma_hdmi/m_axi_mm2s_aclk axi_vdma_hdmi/m_axis_mm2s_aclk \
    xrgb_to_rgb/aclk v_vid_out_hdmi/aclk
bd_net ps7_0/FCLK_CLK2 rst_rp_fast/slowest_sync_clk dfx_sync/fast_clk rp_accel/fast_clk
bd_net clk_wiz_hdmi/clk_out1 vtg_hdmi/clk v_vid_out_hdmi/vid_io_out_clk dvi_tx_hdmi/pclk
bd_net clk_wiz_hdmi/clk_out2 dvi_tx_hdmi/pclk_x5
bd_net clk_wiz_hdmi/locked dvi_tx_hdmi/reset_n
bd_net v_vid_out_hdmi/vtg_ce vtg_hdmi/gen_clken

# --- resets -----------------------------------------------------------------
bd_net ps7_0/FCLK_RESET0_N rst_ps_100/ext_reset_in rst_ps_142/ext_reset_in \
    rst_rp_ctrl/ext_reset_in rst_rp_fast/ext_reset_in
bd_net rst_ps_100/peripheral_reset clk_wiz_hdmi/reset
bd_net rst_ps_100/peripheral_aresetn gp0_periph/ARESETN gp0_periph/S00_ARESETN \
    gp0_periph/M00_ARESETN gp0_periph/M01_ARESETN gp0_periph/M02_ARESETN \
    gp0_periph/M03_ARESETN hp2_intercon/ARESETN hp2_intercon/S00_ARESETN \
    hp2_intercon/M00_ARESETN sdm_ctrl/resetn sdm_mem/resetn dfx_gpio/s_axi_aresetn \
    axi_intc_0/s_axi_aresetn axi_vdma_hdmi/axi_resetn
bd_net rst_ps_142/peripheral_aresetn hp0_intercon/ARESETN hp0_intercon/S00_ARESETN \
    hp0_intercon/M00_ARESETN xrgb_to_rgb/aresetn v_vid_out_hdmi/aresetn
bd_net rst_rp_ctrl/peripheral_aresetn rp_accel/ctrl_resetn
bd_net rst_rp_fast/peripheral_aresetn rp_accel/fast_resetn

# --- DFX control and interrupts ---------------------------------------------
bd_net dfx_gpio/gpio_io_o dfx_sync/gpio_ctrl
bd_net dfx_sync/gpio_status dfx_gpio/gpio2_io_i
bd_net dfx_sync/shutdown_req sdm_ctrl/request_shutdown sdm_mem/request_shutdown
bd_net sdm_ctrl/in_shutdown dfx_sync/ctrl_in_shutdown
bd_net sdm_mem/in_shutdown dfx_sync/mem_in_shutdown
bd_net dfx_sync/ctrl_rp_hold rst_rp_ctrl/aux_reset_in
bd_net dfx_sync/fast_rp_hold rst_rp_fast/aux_reset_in
# *_rp_hold is active high (1 = hold RP in reset). Parameter propagation from
# the active-low FCLK_RESET0_N flips C_AUX_RESET_HIGH to 0, which would hold
# the RP in reset forever, so pin it explicitly (checked after validation).
foreach r {rst_rp_ctrl rst_rp_fast} {
    set_property CONFIG.C_AUX_RESET_HIGH {1} [get_bd_cells $r]
}
bd_net rp_accel/irq irq_concat/In0
bd_net axi_vdma_hdmi/mm2s_introut irq_concat/In1
bd_net irq_concat/dout axi_intc_0/intr
bd_net axi_intc_0/irq ps7_0/IRQ_F2P

# --- address map ------------------------------------------------------------
set ps_data [get_bd_addr_spaces ps7_0/Data]
proc seg_of {intf} { get_bd_addr_segs -of_objects [get_bd_intf_pins $intf] }
assign_bd_address -offset 0x43000000 -range 64K -target_address_space $ps_data [seg_of axi_vdma_hdmi/S_AXI_LITE] -force
assign_bd_address -offset 0x41800000 -range 64K -target_address_space $ps_data [seg_of axi_intc_0/s_axi] -force
assign_bd_address -offset 0x41200000 -range 64K -target_address_space $ps_data [seg_of dfx_gpio/S_AXI] -force
assign_bd_address
# RP control slaves: re-apply the RM's slot map (auto-assign shrinks them to
# each slave's minimum aperture). Anything else inside the RP window is an error.
set static_segs {SEG_axi_vdma_hdmi_Reg SEG_axi_intc_0_Reg SEG_dfx_gpio_Reg}
foreach seg [get_bd_addr_segs -quiet -of_objects $ps_data] {
    set name [file tail $seg]
    if {$name in $static_segs} { continue }
    set placed 0
    foreach {cell slot} [dict get $::rp_ctrl_map $::rp_rm] {
        if {[string match "SEG_${cell}_*" $name]} {
            set_property -dict [list OFFSET [format 0x%08X [expr {$::rp_ctrl_base + $slot * 0x10000}]] RANGE 64K] $seg
            set placed 1
        }
    }
    if {!$placed} { error "unexpected PS address segment $seg" }
}
print_bd_addresses
validate_bd_design
foreach r {rst_rp_ctrl rst_rp_fast} {
    set aux [get_property CONFIG.C_AUX_RESET_HIGH [get_bd_cells $r]]
    puts "RESET_CHECK $r C_AUX_RESET_HIGH=$aux"
    if {$aux != 1} { error "$r aux_reset_in must be active high (rp_hold), got C_AUX_RESET_HIGH=$aux" }
}
save_bd_design

make_wrapper -files [get_files shell.bd] -top -import
set_property top shell_wrapper [current_fileset]
puts "SHELL_BD_READY"
