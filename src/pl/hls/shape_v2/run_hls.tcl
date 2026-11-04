# Vitis HLS flow for the v2 streaming shape kernel.
# Env: SHAPE_HLS_STAGE (csim|csynth|cosim|export), SHAPE_HLS_FIXTURE (fixture dir,
# also provides shape_weights.hpp), SHAPE_HLS_PROJECT (project dir; csim creates
# it fresh, later stages reuse it), SHAPE_HLS_IP_OUTPUT (export only).
# The testbench is the unchanged v1 test_top.cpp (150 cases in csim, cases
# 13/73/130 in cosim) comparing against the frozen expected.bin oracle.
foreach name {SHAPE_HLS_STAGE SHAPE_HLS_FIXTURE SHAPE_HLS_PROJECT} {
    if {![info exists ::env($name)]} { error "missing environment variable: $name" }
}
set stage $::env(SHAPE_HLS_STAGE)
set fixture [file normalize $::env(SHAPE_HLS_FIXTURE)]
set project [file normalize $::env(SHAPE_HLS_PROJECT)]
set source [file dirname [file normalize [info script]]]
if {$stage ni {csim csynth cosim export}} { error "invalid stage: $stage" }
if {$stage eq "csim"} { file delete -force $project }
if {$stage ne "csim" && ![file isdirectory $project]} { error "project missing: $project" }

open_project $project
set_top shape_top
set flags [format {-std=c++14 -I%s -I%s} $source $fixture]
set tb_flags $flags
if {$stage eq "cosim"} { append tb_flags { -DSHAPE_COSIM} }
add_files [file join $source shape_stream.cpp] -cflags $flags
add_files -tb [file join $source test_top.cpp] -cflags $tb_flags
open_solution solution1 -flow_target vivado
set_part xc7z020clg400-1
create_clock -period 10 -name default
switch $stage {
    csim   { csim_design }
    csynth { csynth_design }
    cosim  { cosim_design -rtl verilog -tool xsim }
    export {
        set output [file normalize $::env(SHAPE_HLS_IP_OUTPUT)]
        export_design -format ip_catalog -version 2.0 -output $output
    }
}
close_project
exit
