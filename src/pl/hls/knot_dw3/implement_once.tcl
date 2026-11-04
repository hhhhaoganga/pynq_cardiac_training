# One place/route attempt. Preserve failed checkpoints; never retry directives.
lassign $argv prepared static out
set_param general.maxThreads 16
file mkdir $out
set out [file normalize $out]
proc mark {stage} {
    global out
    set f [open $out/stage.txt w]; puts $f $stage; close $f
    puts "KNOT_STAGE $stage"
}
proc diagnostics {tag} {
    global out
    catch {write_checkpoint -force $out/${tag}.dcp}
    catch {report_route_status -file $out/${tag}_route_status.rpt}
    catch {report_timing_summary -max_paths 20 -file $out/${tag}_timing.rpt}
    catch {report_drc -file $out/${tag}_drc.rpt}
    catch {report_design_analysis -congestion -min_congestion_level 3 -file $out/${tag}_congestion.rpt}
    set f [open $out/${tag}_conflict_nets.txt w]
    foreach n [get_nets -hier -quiet -filter {ROUTE_STATUS == CONFLICTS}] {puts $f $n}
    close $f
}
open_checkpoint $prepared
mark optimization
if {[catch {opt_design} why]} {diagnostics opt_failure; error $why}
foreach pb {pb_pw pb_dw} {report_utilization -pblocks [get_pblocks $pb] -file $out/opt_${pb}.rpt}
mark placement
if {[catch {place_design -directive Default} why]} {diagnostics place_failure; error $why}
report_design_analysis -congestion -min_congestion_level 3 -file $out/placed_congestion.rpt
mark physical_optimization
if {[catch {phys_opt_design -directive AggressiveExplore} why]} {diagnostics physopt_failure; error $why}
write_checkpoint -force $out/placed.dcp
foreach pb {pb_pw pb_dw} {report_utilization -pblocks [get_pblocks $pb] -file $out/placed_${pb}.rpt}
report_utilization -pblocks [get_pblocks pblock_rp_accel] -file $out/placed_rp.rpt
report_utilization -file $out/placed_full.rpt
report_design_analysis -congestion -min_congestion_level 3 -file $out/physopt_congestion.rpt
mark routing
set failed [catch {route_design -directive Default} why]
diagnostics routed
if {$failed} {mark route_failed; error $why}
set f [open $out/routed_route_status.rpt r]; set report [read $f]; close $f
if {![regexp {# of nets with routing errors[^\n]*:\s*([0-9]+)} $report -> errors]} {
    error "Cannot establish complete routing from report"
}
if {$errors != 0} {mark route_failed; error "Routing errors: $errors"}
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {![llength $setup] || ![llength $hold]} {error "Missing timing paths"}
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
set drc [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set f [open $out/result.txt w]
puts $f "WNS=$wns WHS=$whs DRC_ERRORS=$drc ROUTING_ERRORS=$errors";close $f
if {$wns < 0 || $whs < 0 || $drc > 0} {mark timing_or_drc_failed; error "Acceptance gate failed"}
mark static_compatibility
close_design
pr_verify $static $out/routed.dcp -file $out/pr_verify.rpt
mark implementation_passed
puts KNOT_IMPL_PASS
# Bitstream generation is separate and requires RTL cosimulation PASS as well.
