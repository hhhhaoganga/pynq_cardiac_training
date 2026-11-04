lassign $argv checkpoint out
open_checkpoint $checkpoint
write_bitstream -force -bin_file $out/dfx_full_knot_dw3.bit
write_bitstream -force -cell shell_i/rp_accel -bin_file $out/dfx_partial_knot_dw3.bit
puts KNOT_BITSTREAMS_DONE
