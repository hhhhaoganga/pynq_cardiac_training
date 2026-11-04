# Phase 1 build: synth + impl + bitstream for shell + rm_seg (flat).
# Gates: setup/hold slack >= 0 and no error-level DRC (see export_checked_build).
source [file join [file dirname [info script]] common.tcl]
set_param general.maxThreads 16
set proj_dir $::dfx_work/$::dfx_proj

open_project $proj_dir/$::dfx_proj.xpr
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property -dict [list STEPS.PHYS_OPT_DESIGN.IS_ENABLED true \
    STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true] [get_runs impl_1]

reset_run synth_1
launch_runs synth_1 -jobs 32
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} { error "Synthesis failed" }
# No -to_step: run every enabled step, including post-route phys_opt.
launch_runs impl_1 -jobs 32
wait_on_run impl_1
if {![impl_run_ok impl_1]} { error "Implementation failed" }

open_run impl_1
set ok [export_checked_build $proj_dir $::dfx_out/$::dfx_proj $::dfx_proj]
close_project
if {!$ok} { error "Timing/DRC gate failed (bitstream written as _UNCHECKED)" }
puts "[string toupper $::dfx_proj]_BUILD_CHECKED"
