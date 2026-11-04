# Flat (non-DFX) project = static shell + one reconfigurable module in one
# bitstream. Usage (tclargs): create_project.tcl <rm_seg|rm_shape>
# The RM lives in a block design container so the DFX phase only has to enable it.
source [file join [file dirname [info script]] common.tcl]
set_param general.maxThreads 16

set proj_dir $::dfx_work/$::dfx_proj
file delete -force $proj_dir
create_project $::dfx_proj $proj_dir -part $::dfx_part
set_property target_language Verilog [current_project]
# Prefer the v2 streaming shape kernel when it has been exported (same as create_dfx.tcl).
set shape_repo [expr {[file isdirectory $::dfx_src/ip_repo_shape_v2] ? "$::dfx_src/ip_repo_shape_v2" : "$::dfx_src/ip_repo_shape"}]
puts "SHAPE_REPO $shape_repo"
set_property ip_repo_paths [list $::dfx_src/ip_repo $shape_repo] [current_project]
update_ip_catalog

if {$::rp_rm eq "rm_seg"} {
    # Accelerator RTL: every non-testbench source from the verified tree, except
    # files replaced by a same-named copy in pynq_dfx/rtl_override (timing fixes
    # on top of the frozen sources; src/ itself stays hash-identical).
    set overrides {}
    foreach f [lsort [glob -nocomplain $::dfx_src/pl/override/*.sv $::dfx_src/pl/override/*.v]] {
        dict set overrides [file tail $f] $f
        puts "RTL_OVERRIDE [file tail $f]"
    }
    set rtl {}
    set hdr {}
    foreach f [lsort [glob $::dfx_src/pl/profile_rtl/*]] {
        set name [file tail $f]
        if {[string match *_tb.sv $name] || $name eq "camus_dual_datamover_ddr_model.sv"} { continue }
        if {[dict exists $overrides $name]} { set f [dict get $overrides $name] }
        switch -glob -- $name {
            *.svh   { lappend hdr $f }
            *.sv    - *.v { lappend rtl $f }
        }
    }
    add_files -norecurse $rtl
    add_files -norecurse $hdr
    set_property file_type {Verilog Header} [get_files $hdr]
    add_files -norecurse [glob $::dfx_src/pl/pl_rom_se_candidate/*.mem]
    set_property include_dirs [list $::dfx_src/profile_rtl] [current_fileset]
}
add_files -norecurse [list $::dfx_root/rtl/dfx_ctrl_sync.v $::dfx_root/rtl/rp_mem_adapter.v \
    $::dfx_root/rtl/rp_ctrl_split.v $::dfx_root/rtl/vtg_720p.v]
add_files -fileset constrs_1 -norecurse $::dfx_src/pl/pynq_z2_hdmi.xdc
update_compile_order -fileset sources_1

source $::dfx_root/scripts/bd_$::rp_rm.tcl
source $::dfx_root/scripts/bd_shell.tcl
update_compile_order -fileset sources_1
close_project
puts "PROJECT_READY $proj_dir"
