set here [file dirname [file normalize [info script]]]
set ::env(CNN_FIX) [file join $here fixtures]
cd $here
open_project [file join $here hls_project]
set_top cnn_top
set flags [format {-std=c++14 -I%s -I%s} $here [file join $here fixtures knot]]
add_files [file join $here cnn_engine.cpp] -cflags $flags
add_files -tb [file join $here check_rtl.cpp] -cflags $flags
open_solution solution1 -flow_target vivado
set_part xc7z020clg400-1
create_clock -period 10 -name default
config_interface -m_axi_addr64=false
csim_design
csynth_design
cosim_design -rtl verilog -tool xsim -trace_level none
close_project
puts KNOT_MAC64_VALIDATION_PASS
exit
