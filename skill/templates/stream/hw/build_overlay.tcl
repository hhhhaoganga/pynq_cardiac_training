# vivado -mode batch -source hw/build_overlay.tcl   (run from the project root; or hw/run_vivado.bat)
# PS7 (PYNQ-Z2 preset) + AXI DMA (simple mode) + HLS axis_scale:
#   GP0 -> ctrl_ic -> {axis_scale_0/s_axi_control, axi_dma_0/S_AXI_LITE}
#   axi_dma_0 M_AXIS_MM2S -> axis_scale_0/in_s,  axis_scale_0/out_s -> S_AXIS_S2MM
#   axi_dma_0 M_AXI_MM2S + M_AXI_S2MM -> mem_ic -> HP0.   FCLK0 100 MHz.
set root [file normalize [pwd]]
set name axis_scale
# BD name must differ from the HLS top module name, else synth sees 'illegal module recursion'.
set bd ${name}_bd
file mkdir $root/build/out
create_project -force ovl $root/build/ovl -part xc7z020clg400-1
set_property ip_repo_paths $root/hls_prj/sol1/impl/ip [current_project]
update_ip_catalog
create_bd_design $bd

source $root/hw/ps7_pynq_z2.tcl
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP1 {0} CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} CONFIG.PCW_EN_CLK1_PORT {0} CONFIG.PCW_EN_CLK2_PORT {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} $ps7_0

create_bd_cell -type ip -vlnv skill:hls:axis_scale:1.0 axis_scale_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
# Simple (register) mode, which pynq's DMA driver uses. Buffer length width 23 bits = 8 MB
# per transfer; the 14-bit default silently caps a transfer at 16 KB.
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_sg_length_width {23} \
    CONFIG.c_m_axi_mm2s_data_width {32} CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_m_axi_s2mm_data_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} CONFIG.c_s2mm_burst_size {16}] [get_bd_cells axi_dma_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0
# axi_interconnect, not smartconnect: far fewer sub-cores to generate (Windows slave-interp failures).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ctrl_ic
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells ctrl_ic]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 mem_ic
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells mem_ic]

connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0] [get_bd_intf_pins ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M00_AXI] [get_bd_intf_pins axis_scale_0/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M01_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins axis_scale_0/in_s]
connect_bd_intf_net [get_bd_intf_pins axis_scale_0/out_s] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins mem_ic/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_ic/M00_AXI] [get_bd_intf_pins ps7_0/S_AXI_HP0]

# One get_bd_pins call with an explicit pin list ({*}-expanded lists turn into plain strings).
connect_bd_net -net fclk0 [get_bd_pins {ps7_0/FCLK_CLK0 ps7_0/M_AXI_GP0_ACLK ps7_0/S_AXI_HP0_ACLK
    axis_scale_0/ap_clk axi_dma_0/s_axi_lite_aclk axi_dma_0/m_axi_mm2s_aclk axi_dma_0/m_axi_s2mm_aclk
    rst_0/slowest_sync_clk ctrl_ic/ACLK ctrl_ic/S00_ACLK ctrl_ic/M00_ACLK ctrl_ic/M01_ACLK
    mem_ic/ACLK mem_ic/S00_ACLK mem_ic/S01_ACLK mem_ic/M00_ACLK}]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
# Interconnect ARESETN needs interconnect_aresetn; per-port resets take peripheral_aresetn.
connect_bd_net [get_bd_pins {rst_0/interconnect_aresetn ctrl_ic/ARESETN mem_ic/ARESETN}]
connect_bd_net [get_bd_pins {rst_0/peripheral_aresetn axis_scale_0/ap_rst_n axi_dma_0/axi_resetn
    ctrl_ic/S00_ARESETN ctrl_ic/M00_ARESETN ctrl_ic/M01_ARESETN
    mem_ic/S00_ARESETN mem_ic/S01_ARESETN mem_ic/M00_ARESETN}]

assign_bd_address
validate_bd_design
save_bd_design

# Global synthesis (no per-IP OOC runs) and retried generation: Windows Vivado sometimes
# fails "Could not create slave interpreter" on one IP; a rerun continues from the cache.
set_property synth_checkpoint_mode None [get_files $bd.bd]
for {set i 1} {$i <= 3} {incr i} {
    if {![catch {generate_target all [get_files $bd.bd]} err]} break
    puts "generate_target try $i failed: $err"
    if {$i == 3} { error "generate_target failed 3 times" }
}
make_wrapper -files [get_files $bd.bd] -top
add_files -norecurse [glob $root/build/ovl/ovl.gen/sources_1/bd/$bd/hdl/${bd}_wrapper.v]
set_property top ${bd}_wrapper [current_fileset]

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "impl_1 failed" }

open_run impl_1
report_timing_summary -file $root/build/out/timing.rpt
report_utilization    -file $root/build/out/utilization.rpt
file copy -force [glob $root/build/ovl/ovl.runs/impl_1/*.bit] $root/build/out/$name.bit
file copy -force [glob $root/build/ovl/ovl.gen/sources_1/bd/$bd/hw_handoff/$bd.hwh] $root/build/out/$name.hwh
puts "OVERLAY_BUILD_DONE"
