lassign $argv checkpoint out
open_checkpoint $checkpoint
report_utilization -pblocks [get_pblocks pb_sv_compute] -file $out/final_compute_utilization.rpt
report_utilization -pblocks [get_pblocks pblock_rp_accel] -file $out/final_rp_utilization.rpt
report_utilization -file $out/final_full_utilization.rpt
report_clocks -file $out/final_clocks.rpt
puts SV_HAND_FINAL_RESOURCES_SAVED
