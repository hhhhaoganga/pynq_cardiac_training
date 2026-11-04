# vitis_hls -f hls/run_hls.tcl   (run from the project root)
set root [file normalize [pwd]]
file mkdir $root/sim/out
open_project -reset hls_prj
set_top vadd
add_files hls/vadd.cpp
add_files -tb hls/tb.cpp
open_solution -reset sol1 -flow_target vivado
set_part xc7z020clg400-1
create_clock -period 10 -name default
csim_design
csynth_design
cosim_design
export_design -format ip_catalog -ipname vadd -vendor skill -library hls -version 1.0
exit
