lassign $argv checkpoint out
open_checkpoint $checkpoint
write_bitstream -force -bin_file $out/dfx_full_knot_sv.bit
write_bitstream -force -cell shell_i/rp_accel -bin_file $out/dfx_partial_knot_sv.bit
puts SV_KNOT_BITSTREAMS_DONE
