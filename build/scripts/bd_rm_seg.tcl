# Reconfigurable module: SE U-Net W4A8 segmentation (rm_seg.bd).
# Reproduces the verified three-stage accelerator subsystem from
# echocardiography.srcs/.../pynq_ps_base.bd, re-homed behind the RP boundary.
# IP parameters and connectivity are copied verbatim from that design.
source [file join [file dirname [info script]] common.tcl]
source [file join [file dirname [info script]] rp_boundary.tcl]

create_bd_design rm_seg
create_rp_boundary

create_bd_cell -type module -reference camus_stream_pipeline_ref camus_stream_rtl

set dm_cfg [list \
    CONFIG.c_include_mm2s {Full} CONFIG.c_include_s2mm {Full} \
    CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_include_mm2s_dre {false} CONFIG.c_include_s2mm_dre {false} \
    CONFIG.c_mm2s_btt_used {23} CONFIG.c_s2mm_btt_used {23} \
    CONFIG.c_mm2s_burst_size {16} CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_mm2s_include_sf {true} CONFIG.c_include_mm2s_stsfifo {true} \
    CONFIG.c_include_s2mm_stsfifo {true} \
    CONFIG.c_m_axi_mm2s_id_width {3} CONFIG.c_m_axi_s2mm_id_width {3}]
set up_cfg   [list CONFIG.S_TDATA_NUM_BYTES {8}  CONFIG.M_TDATA_NUM_BYTES {16} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1}]
set down_cfg [list CONFIG.S_TDATA_NUM_BYTES {16} CONFIG.M_TDATA_NUM_BYTES {8}  CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1}]

set stages {enc dec post}
foreach s $stages {
    bd_ip xilinx.com:ip:axi_datamover:* camus_stream_dm_$s $dm_cfg
    bd_ip xilinx.com:ip:axis_dwidth_converter:* camus_${s}_mm2s_dw $up_cfg
    bd_ip xilinx.com:ip:axis_dwidth_converter:* camus_${s}_s2mm_dw $down_cfg
}
bd_ip xilinx.com:ip:axi_interconnect:* camus_mem_intercon [list CONFIG.NUM_SI {6} CONFIG.NUM_MI {1}]

# Datapath: RTL <-> DataMover command/status/stream, DataMover -> interconnect.
# The whole RM, including the 6:1 interconnect, is on ctrl_clk (100 MHz): the
# original 142.857 MHz memory domain needed six AXI clock converters here.
set si 0
foreach s $stages {
    set S [string toupper $s]
    set dm camus_stream_dm_$s
    bd_link camus_stream_rtl/M_AXIS_${S}_MM2S_CMD $dm/S_AXIS_MM2S_CMD
    bd_link $dm/M_AXIS_MM2S_STS camus_stream_rtl/S_AXIS_${S}_MM2S_STS
    bd_link $dm/M_AXIS_MM2S camus_${s}_mm2s_dw/S_AXIS
    bd_link camus_${s}_mm2s_dw/M_AXIS camus_stream_rtl/S_AXIS_${S}_MM2S
    bd_link camus_stream_rtl/M_AXIS_${S}_S2MM_CMD $dm/S_AXIS_S2MM_CMD
    bd_link $dm/M_AXIS_S2MM_STS camus_stream_rtl/S_AXIS_${S}_S2MM_STS
    bd_link camus_stream_rtl/M_AXIS_${S}_S2MM camus_${s}_s2mm_dw/S_AXIS
    bd_link camus_${s}_s2mm_dw/M_AXIS $dm/S_AXIS_S2MM
    bd_link $dm/M_AXI_MM2S camus_mem_intercon/[format S%02d_AXI $si]
    bd_link $dm/M_AXI_S2MM camus_mem_intercon/[format S%02d_AXI [expr {$si + 1}]]
    bd_net $dm/mm2s_err camus_stream_rtl/${s}_mm2s_error
    bd_net $dm/s2mm_err camus_stream_rtl/${s}_s2mm_error
    incr si 2
}
bd_link S_AXI_CTRL camus_stream_rtl/S_AXI_CTRL
# 6 DataMover masters x 3-bit IDs -> 6-bit IDs on the interconnect master.
add_rp_mem_adapter camus_mem_intercon/M00_AXI 6
bd_net camus_stream_rtl/irq irq

# Single clock domain: accelerator, DataMovers, width converters, interconnect.
set clk_pins {camus_stream_rtl/aclk camus_mem_intercon/ACLK camus_mem_intercon/M00_ACLK}
set rst_pins {camus_stream_rtl/aresetn camus_mem_intercon/ARESETN camus_mem_intercon/M00_ARESETN}
for {set i 0} {$i < 6} {incr i} {
    lappend clk_pins camus_mem_intercon/[format S%02d_ACLK $i]
    lappend rst_pins camus_mem_intercon/[format S%02d_ARESETN $i]
}
foreach s $stages {
    set dm camus_stream_dm_$s
    lappend clk_pins $dm/m_axi_mm2s_aclk $dm/m_axi_s2mm_aclk \
        $dm/m_axis_mm2s_cmdsts_aclk $dm/m_axis_s2mm_cmdsts_awclk \
        camus_${s}_mm2s_dw/aclk camus_${s}_s2mm_dw/aclk
    lappend rst_pins $dm/m_axi_mm2s_aresetn $dm/m_axi_s2mm_aresetn \
        $dm/m_axis_mm2s_cmdsts_aresetn $dm/m_axis_s2mm_cmdsts_aresetn \
        camus_${s}_mm2s_dw/aresetn camus_${s}_s2mm_dw/aresetn
}
bd_net ctrl_clk {*}$clk_pins
bd_net ctrl_resetn {*}$rst_pins

# Addressing inside the RM: control registers at the slot base, DataMovers see all DDR.
assign_rm_ctrl rm_seg
set mem_spaces {}
foreach s $stages {
    foreach ch {MM2S S2MM} { lappend mem_spaces camus_stream_dm_$s/Data_$ch }
}
assign_rp_mem $mem_spaces
fit_rp_mem_adapter camus_mem_intercon/M00_AXI
print_bd_addresses
check_rp_boundary camus_mem_intercon/M00_AXI
dump_rp_boundary $::dfx_out/boundary_rm_seg.txt
save_bd_design
close_bd_design [current_bd_design]
puts "RM_SEG_BD_READY"
