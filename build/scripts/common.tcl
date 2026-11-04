# Shared paths and block-design helpers for the PYNQ-Z2 DFX flow.
# Layout: <pkg>/build/scripts (this tree), <pkg>/src, <pkg>/build/{ref,work,out}.
set ::dfx_root [file dirname [file dirname [file normalize [info script]]]]
set ::dfx_pkg  [file dirname $::dfx_root]
set ::dfx_ws   $::dfx_pkg
set ::dfx_src  $::dfx_ws/src
set ::dfx_ref  $::dfx_root/ref
set ::dfx_work $::dfx_root/work
set ::dfx_out  $::dfx_root/out
set ::dfx_part xc7z020clg400-1

# Reconfigurable module built by this invocation (first tclarg, default rm_seg).
# Project/output name: rm_seg -> shell_seg, rm_shape -> shell_shape.
if {![info exists ::rp_rm]} {
    set ::rp_rm [expr {[info exists ::argv] && [llength $::argv] ? [lindex $::argv 0] : "rm_seg"}]
}
if {$::rp_rm ni {rm_seg rm_shape}} { error "unknown reconfigurable module: $::rp_rm" }
set ::dfx_proj shell_[string range $::rp_rm 3 end]

# FCLK frequencies exactly as the PYNQ-Z2 base PS7 preset reports them.
set ::fclk0_hz 100000000
set ::fclk1_hz 142857132
set ::fclk2_hz 200000000

# Highest installed version of an IP matching a VLNV glob.
proc pick_vlnv {pattern} {
    set defs [lsort -dictionary [get_ipdefs -all $pattern]]
    if {![llength $defs]} { error "No IP matches $pattern" }
    return [lindex $defs end]
}

proc bd_ip {pattern name {cfg {}}} {
    set cell [create_bd_cell -type ip -vlnv [pick_vlnv $pattern] $name]
    if {[llength $cfg]} { set_property -dict $cfg $cell }
    return $cell
}

# "cell/pin" names a cell pin; a bare name is a top-level port.
proc bd_obj {path} {
    if {[string first / $path] < 0} {
        set obj [get_bd_ports -quiet /$path]
    } else {
        set obj [get_bd_pins -quiet $path]
    }
    if {![llength $obj]} { error "No BD pin/port: $path" }
    return $obj
}

proc bd_intf {path} {
    if {[string first / $path] < 0} {
        set obj [get_bd_intf_ports -quiet /$path]
    } else {
        set obj [get_bd_intf_pins -quiet $path]
    }
    if {![llength $obj]} { error "No BD interface: $path" }
    return $obj
}

# Connect one driver to all listed sinks in a single net.
proc bd_net {args} {
    set objs {}
    foreach p $args { lappend objs [bd_obj $p] }
    connect_bd_net {*}$objs
}

proc bd_link {a b} {
    connect_bd_intf_net [bd_intf $a] [bd_intf $b]
}

# An implementation run routed without errors (timing is gated separately).
# STATUS text differs between -to_step and full runs, so check the step marker.
proc impl_run_ok {run} {
    set r [get_runs $run]
    set status [get_property STATUS $r]
    puts "RUN $run STATUS=\"$status\" PROGRESS=[get_property PROGRESS $r]"
    if {[string match -nocase *error* $status]} { return 0 }
    return [file exists [get_property DIRECTORY $r]/.route_design.end.rst]
}

# Report, gate and write the bitstream of the currently opened routed design.
# A design failing setup/hold/DRC is still written, with an _UNCHECKED suffix.
proc export_checked_build {proj_dir out name} {
    file mkdir $out
    report_timing_summary -max_paths 20 -file $out/timing.rpt
    report_utilization -file $out/utilization.rpt
    report_utilization -hierarchical -hierarchical_depth 3 -file $out/hierarchy.rpt
    report_drc -file $out/drc.rpt
    report_cdc -file $out/cdc.rpt
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    set drc_err [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
    puts "BUILD_RESULT WNS=$wns WHS=$whs DRC_ERRORS=$drc_err"
    set ok [expr {$wns >= 0 && $whs >= 0 && $drc_err == 0}]
    set tag [expr {$ok ? "" : "_UNCHECKED"}]
    write_checkpoint -force $out/${name}_routed.dcp
    write_bitstream -force -bin_file $out/$name$tag.bit
    set hwh [lindex [glob -nocomplain \
        $proj_dir/*.gen/sources_1/bd/shell/hw_handoff/shell.hwh \
        $proj_dir/*.srcs/sources_1/bd/shell/hw_handoff/shell.hwh] 0]
    if {$hwh ne ""} { file copy -force $hwh $out/$name$tag.hwh } else { puts "WARNING: shell.hwh not found" }
    return $ok
}

proc print_bd_addresses {} {
    foreach space [get_bd_addr_spaces -hierarchical -quiet] {
        foreach seg [get_bd_addr_segs -quiet -of_objects $space] {
            puts [format "ADDR %-60s %s %s" $seg [get_property OFFSET $seg] [get_property RANGE $seg]]
        }
    }
}
