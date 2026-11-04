# Reconfigurable module: E-PiVox K16 W8A8 shape-coefficient predictor (rm_shape.bd).
# Frozen HLS kernel shape_top (handoff shape_top_ip_20260924_v1) fed by an AXI
# DMA in simple mode, behind the same RP boundary as rm_seg.
#   0x4000_0000: AXI DMA  MM2S 100,352 B input, S2MM 16 B coefficients
#   0x4000_0080: shape_top ap_ctrl_hs (0x00 ctrl, 0x04 GIE, 0x08 IER, 0x0C ISR)
#   (rp_ctrl_split behind the 8-bit S_AXI_CTRL boundary)
#   irq: DMA s2mm_introut (coefficients written to DDR)
# Everything, including the 2:1 memory interconnect, runs on ctrl_clk
# (100 MHz, the kernel's routed/verified clock).
source [file join [file dirname [info script]] common.tcl]
source [file join [file dirname [info script]] rp_boundary.tcl]

create_bd_design rm_shape
create_rp_boundary

bd_ip xilinx.com:hls:shape_top:* shape_core
bd_ip xilinx.com:ip:axi_dma:* shape_dma [list \
    CONFIG.c_include_sg {0} CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {1} CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} CONFIG.c_s2mm_burst_size {16}]
bd_ip xilinx.com:ip:axi_interconnect:* shape_mem_ic [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}]

add_rp_ctrl_split shape_dma/S_AXI_LITE shape_core/s_axi_control
bd_link shape_dma/M_AXIS_MM2S shape_core/input_r
bd_link shape_core/output_r shape_dma/S_AXIS_S2MM
bd_link shape_dma/M_AXI_MM2S shape_mem_ic/S00_AXI
bd_link shape_dma/M_AXI_S2MM shape_mem_ic/S01_AXI
bd_net shape_dma/s2mm_introut irq

bd_net ctrl_clk shape_core/ap_clk shape_dma/s_axi_lite_aclk shape_dma/m_axi_mm2s_aclk \
    shape_dma/m_axi_s2mm_aclk shape_mem_ic/ACLK shape_mem_ic/M00_ACLK \
    shape_mem_ic/S00_ACLK shape_mem_ic/S01_ACLK
bd_net ctrl_resetn shape_core/ap_rst_n shape_dma/axi_resetn \
    shape_mem_ic/ARESETN shape_mem_ic/M00_ARESETN shape_mem_ic/S00_ARESETN shape_mem_ic/S01_ARESETN

# The DMA masters carry no ID; the 2:1 interconnect should add one routing
# bit. Start the adapter at 1 and resize it if propagation says otherwise.
add_rp_mem_adapter shape_mem_ic/M00_AXI 1

assign_rm_ctrl rm_shape
assign_rp_ctrl_split shape_dma/S_AXI_LITE shape_core/s_axi_control
assign_rp_mem {shape_dma/Data_MM2S shape_dma/Data_S2MM}
fit_rp_mem_adapter shape_mem_ic/M00_AXI
print_bd_addresses
check_rp_boundary shape_mem_ic/M00_AXI
dump_rp_boundary $::dfx_out/boundary_rm_shape.txt
save_bd_design
close_bd_design [current_bd_design]
puts "RM_SHAPE_BD_READY"
