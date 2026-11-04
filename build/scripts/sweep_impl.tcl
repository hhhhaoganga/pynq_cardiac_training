# Implementation strategy sweep for shell_seg. Reuses the finished synth_1,
# runs several strategies in parallel (all with phys_opt + post-route phys_opt),
# then exports the best run that meets setup/hold. If none does, the best-WNS
# run is exported as _UNCHECKED so it can be inspected but not mistaken.
source [file join [file dirname [info script]] common.tcl]
set proj_dir $::dfx_work/$::dfx_proj
open_project $proj_dir/$::dfx_proj.xpr
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
    launch_runs synth_1 -jobs 32
    wait_on_run synth_1
    if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} { error "Synthesis failed" }
}

set wanted {
    Performance_Explore Performance_ExplorePostRoutePhysOpt Performance_ExtraTimingOpt
    Performance_NetDelay_high Performance_Retiming Performance_RefinePlacement
    Performance_SpreadLogic_high Congestion_SpreadLogic_high Vivado_Implementation_Defaults
}
set available [list_property_value strategy [get_runs impl_1]]
set flow [get_property FLOW [get_runs impl_1]]
set runs {}
foreach s $wanted {
    if {[lsearch -exact $available $s] < 0} { puts "SKIP strategy $s (not available)"; continue }
    set name sweep_[string tolower $s]
    if {[llength [get_runs -quiet $name]]} { delete_runs $name }
    create_run $name -parent_run synth_1 -flow $flow -strategy $s
    set_property -dict [list STEPS.PHYS_OPT_DESIGN.IS_ENABLED true \
        STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true] [get_runs $name]
    lappend runs $name
}
if {![llength $runs]} { error "No sweep strategies available" }
launch_runs $runs -jobs [llength $runs]
foreach r $runs { wait_on_run $r }

# Prefer a run that meets setup and hold; among equals, the larger WNS.
set best ""; set best_pass 0; set best_wns -1e9
foreach r $runs {
    if {![impl_run_ok $r]} { puts "SWEEP $r FAILED"; continue }
    if {[catch {
        set wns [get_property STATS.WNS [get_runs $r]]
        set whs [get_property STATS.WHS [get_runs $r]]
    } err]} { puts "SWEEP $r no timing stats: $err"; continue }
    set pass [expr {$wns >= 0 && $whs >= 0}]
    puts [format "SWEEP %-45s WNS=%s WHS=%s PASS=%d" $r $wns $whs $pass]
    if {($pass && !$best_pass) || ($pass == $best_pass && $wns > $best_wns)} {
        set best $r; set best_pass $pass; set best_wns $wns
    }
}
if {$best eq ""} { error "No sweep run completed routing" }
puts "SWEEP_BEST $best STRATEGY=[get_property STRATEGY [get_runs $best]] WNS=$best_wns PASS=$best_pass"

open_run $best
set ok [export_checked_build $proj_dir $::dfx_out/$::dfx_proj $::dfx_proj]
close_project
if {!$ok} { error "Timing/DRC gate failed (best run $best written as _UNCHECKED)" }
puts "[string toupper $::dfx_proj]_BUILD_CHECKED run=$best"
