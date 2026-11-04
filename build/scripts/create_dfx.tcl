# DFX project: one static shell, rp_accel as a reconfigurable block design
# container with two RMs (rm_seg, rm_shape). impl_1 = static + rm_seg (parent),
# child_shape = locked static + rm_shape. Produces full and partial bitstreams.
# Usage (tclargs): create_dfx.tcl <base|wide> [impl strategy] [tag]
#   pblock variant; optional strategy (default Performance_Retiming) and a tag
#   that makes the project shell_dfx_<variant>_<tag> (build with variant <variant>_<tag>).
set ::rp_rm rm_seg
source [file join [file dirname [info script]] common.tcl]
set_param general.maxThreads 16
set ::dfx_variant [expr {[llength $::argv] ? [lindex $::argv 0] : "base"}]
set impl_strategy [expr {[llength $::argv] > 1 ? [lindex $::argv 1] : "Performance_Retiming"}]
set proj_tag [expr {[llength $::argv] > 2 ? "_[lindex $::argv 2]" : ""}]
set pblock_xdc [dict get {base rp_pblock.xdc wide rp_pblock_wide.xdc} $::dfx_variant]
set ::dfx_proj shell_dfx_$::dfx_variant$proj_tag
set proj_dir $::dfx_work/$::dfx_proj
puts "DFX_VARIANT $::dfx_variant pblock=$pblock_xdc dir=$proj_dir"
file delete -force $proj_dir
create_project shell_dfx $proj_dir -part $::dfx_part
set_property target_language Verilog [current_project]
set_property PR_FLOW 1 [current_project]
# Prefer the v2 streaming shape kernel when it has been exported.
set shape_repo [expr {[file isdirectory $::dfx_src/ip_repo_shape_v2] ? "$::dfx_src/ip_repo_shape_v2" : "$::dfx_src/ip_repo_shape"}]
puts "DFX_SHAPE_REPO $shape_repo"
set_property ip_repo_paths [list $::dfx_src/ip_repo $shape_repo] [current_project]
update_ip_catalog

# Sources for every RM (same selection as create_project.tcl).
set overrides {}
foreach f [lsort [glob -nocomplain $::dfx_src/pl/override/*.sv $::dfx_src/pl/override/*.v]] {
    dict set overrides [file tail $f] $f
    puts "RTL_OVERRIDE [file tail $f]"
}
set rtl {}; set hdr {}
foreach f [lsort [glob $::dfx_src/pl/profile_rtl/*]] {
    set name [file tail $f]
    if {[string match *_tb.sv $name] || $name eq "camus_dual_datamover_ddr_model.sv"} { continue }
    if {[dict exists $overrides $name]} { set f [dict get $overrides $name] }
    switch -glob -- $name { *.svh { lappend hdr $f } *.sv - *.v { lappend rtl $f } }
}
add_files -norecurse $rtl
add_files -norecurse $hdr
set_property file_type {Verilog Header} [get_files $hdr]
add_files -norecurse [glob $::dfx_src/pl/pl_rom_se_candidate/*.mem]
set_property include_dirs [list $::dfx_src/profile_rtl] [current_fileset]
add_files -norecurse [list $::dfx_root/rtl/dfx_ctrl_sync.v $::dfx_root/rtl/rp_mem_adapter.v \
    $::dfx_root/rtl/rp_ctrl_split.v $::dfx_root/rtl/vtg_720p.v]
add_files -fileset constrs_1 -norecurse [list $::dfx_src/pl/pynq_z2_hdmi.xdc $::dfx_src/pl/$pblock_xdc]
set_property USED_IN {implementation} [get_files $pblock_xdc]
update_compile_order -fileset sources_1

source $::dfx_root/scripts/bd_rm_shape.tcl
source $::dfx_root/scripts/bd_rm_seg.tcl
source $::dfx_root/scripts/bd_shell.tcl

# Turn the container into the reconfigurable partition.
open_bd_design [get_files shell.bd]
set_property -dict [list CONFIG.ENABLE_DFX true \
    CONFIG.LIST_SYNTH_BD {rm_seg.bd:rm_shape.bd} CONFIG.LIST_SIM_BD {rm_seg.bd:rm_shape.bd}] \
    [get_bd_cells rp_accel]
# Fixed apertures = the frozen boundary: the whole 1 MiB control window (room
# for future RMs) and all of DDR for the memory master.
set_property APERTURES [list [list [format 0x%08X $::rp_ctrl_base] $::rp_ctrl_span]] [get_bd_intf_pins rp_accel/S_AXI_CTRL]
set_property APERTURES {{0x00000000 512M}} [get_bd_intf_pins rp_accel/M_AXI_MEM]
validate_bd_design
save_bd_design
close_bd_design [current_bd_design]
# The partition definition and one reconfigurable module per listed BD are
# created when the container's targets are generated.
generate_target all [get_files shell.bd]
make_wrapper -files [get_files shell.bd] -top -import -force
update_compile_order -fileset sources_1

# The BD-level ADDR_WIDTH property says 32 even though the generated container
# port follows the active RM's endpoint, so check the generated HDL: every RM
# must see exactly the frozen control address width.
foreach f [glob [get_property DIRECTORY [current_project]]/shell_dfx.gen/sources_1/bd/shell/bd/rm_*_inst_0/synth/rm_*_inst_0.v] {
    set fh [open $f]; set hdl [read $fh]; close $fh
    if {![regexp {input\s*\[(\d+):0\]\s*S_AXI_CTRL_araddr;} $hdl -> msb]} { error "no S_AXI_CTRL_araddr in $f" }
    puts "RP_BOUNDARY [file tail $f] S_AXI_CTRL_araddr=\[$msb:0\]"
    if {$msb + 1 != $::rp_ctrl_addr_w} { error "[file tail $f]: S_AXI_CTRL address is [expr {$msb + 1}] bits, boundary is $::rp_ctrl_addr_w" }
}

foreach pd [get_partition_defs] {
    puts "DFX_PD $pd module=[get_property MODULE_NAME $pd]"
    foreach rm [get_reconfig_modules -of_objects $pd] { puts "DFX_RM $rm" }
}
set pd [lindex [get_partition_defs] 0]
set rm_seg [lsearch -inline -glob [get_reconfig_modules -of_objects $pd] *rm_seg*]
set rm_shape [lsearch -inline -glob [get_reconfig_modules -of_objects $pd] *rm_shape*]
if {$rm_seg eq "" || $rm_shape eq ""} { error "reconfigurable modules not found" }
set inst shell_i/rp_accel
create_pr_configuration -name cfg_seg -partitions [list $inst:$rm_seg]
create_pr_configuration -name cfg_shape -partitions [list $inst:$rm_shape]
set_property PR_CONFIGURATION cfg_seg [get_runs impl_1]
create_run child_shape -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg_shape
# STRATEGY resets step options, so it must be set before the per-step overrides.
puts "DFX_STRATEGY $impl_strategy"
set_property STRATEGY $impl_strategy [get_runs impl_1]
foreach r {impl_1 child_shape} {
    set_property -dict [list STEPS.PHYS_OPT_DESIGN.IS_ENABLED true \
        STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true \
        STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true] [get_runs $r]
}
close_project
puts "DFX_PROJECT_READY $proj_dir"
