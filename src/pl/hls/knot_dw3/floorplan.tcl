# Knot DW3 partition: reuse the established U-region boundary, but require every
# member to exist in the NEW netlist and audit its actual capacity before routing.
# DW right arm + lower junction; PW bottom; AXI/control left unconstrained.
set rp_pb [get_pblocks pblock_rp_accel]
set u shell_i/rp_accel/u_cnn
proc clip {wanted} {
    global rp_pb
    set out {}
    foreach w $wanted {
        if {![regexp {^(\w+)_X(\d+)Y(\d+):\w+_X(\d+)Y(\d+)$} $w -> t x0 y0 x1 y1]} {error "Bad range $w"}
        foreach p [get_property DERIVED_RANGES $rp_pb] {
            if {![regexp {^(\w+)_X(\d+)Y(\d+):\w+_X(\d+)Y(\d+)$} $p -> pt px0 py0 px1 py1] || $pt ne $t} continue
            set a [expr {max($x0,$px0)}]; set b [expr {min($x1,$px1)}]
            set c [expr {max($y0,$py0)}]; set d [expr {min($y1,$py1)}]
            if {$a <= $b && $c <= $d} {lappend out "${t}_X${a}Y${c}:${t}_X${b}Y${d}"}
        }
    }
    if {![llength $out]} {error "Empty clipped region"}
    return $out
}
proc select_required {patterns} {
    global u
    set result {}
    foreach pattern $patterns {
        set matched [get_cells -quiet $u/$pattern]
        if {![llength $matched]} {error "Missing floorplan member: $pattern"}
        foreach c $matched {lappend result $c}
    }
    return [lsort -unique $result]
}
proc child {name wanted cells} {
    global rp_pb
    set pb [create_pblock $name]
    set_property PARENT $rp_pb $pb
    resize_pblock $pb -add [clip $wanted]
    add_cells_to_pblock $pb $cells
    puts "FP $name members: $cells"
}
set pw_cells [select_required {
    grp_pw_pass_fu_* wt_U outb_U outh_U resb0_U dwb_U
    cnn_top_ap_uint_64_int_int_pin* bias_p_U mult_p_U shift_p_U
    grp_stem_im2col_fu_* grp_rd_pool_fu_* p_ZZ*img*
    grp_load_par_fu_* grp_cnn_top_Pipeline_VITIS_LOOP_116_1_fu_*
}]
set dw_cells [select_required {
    grp_dw_pass_fu_* wd_U cnn_top_ap_uint_64_int_int_lb*
    bias_d_U mult_d_U shift_d_U grp_load_par_1_fu_*
    grp_cnn_top_Pipeline_VITIS_LOOP_129_1_fu_*
}]
foreach c $pw_cells {if {[lsearch -exact $dw_cells $c] >= 0} {error "Overlapping member $c"}}
child pb_pw {
    SLICE_X0Y0:SLICE_X81Y49 SLICE_X82Y0:SLICE_X113Y29
    RAMB36_X0Y0:RAMB36_X3Y9 RAMB36_X4Y0:RAMB36_X5Y5
    RAMB18_X0Y0:RAMB18_X3Y19 RAMB18_X4Y0:RAMB18_X5Y11
    DSP48_X0Y0:DSP48_X2Y19 DSP48_X3Y0:DSP48_X4Y11
} $pw_cells
child pb_dw {
    SLICE_X82Y30:SLICE_X113Y149 RAMB36_X4Y6:RAMB36_X5Y29
    RAMB18_X4Y12:RAMB18_X5Y59 DSP48_X3Y12:DSP48_X4Y59
} $dw_cells
# Rebuilt synthesis/import can leave arithmetic carry primitives at the RP
# root, outside u_cnn. Include unambiguous connected components in the same
# region as their arithmetic neighbours; never infer ownership from names.
set rp_root shell_i/rp_accel
set glue [get_cells -quiet $rp_root/* -filter {IS_PRIMITIVE && REF_NAME != GND && REF_NAME != VCC}]
set glue_set [dict create]
foreach c $glue {dict set glue_set [get_property NAME $c] 1}
proc assigned_group {c} {
    global pw_cells dw_cells
    foreach root $pw_cells {if {$c eq $root || [string first "$root/" $c] == 0} {return PW}}
    foreach root $dw_cells {if {$c eq $root || [string first "$root/" $c] == 0} {return DW}}
    return FREE
}
set adj [dict create]
set touches [dict create]
set shared [get_cells -hier -quiet -filter {IS_PRIMITIVE && (REF_NAME == GND || REF_NAME == VCC || REF_NAME =~ BUFG*)}]
set ignored_nets [dict create]
set shared_pins [get_pins -quiet -of_objects $shared -filter {DIRECTION == OUT}]
foreach n [get_nets -quiet -segments -of_objects $shared_pins] {dict set ignored_nets [get_property NAME $n] 1}
foreach c [dict keys $glue_set] {
    set ns {}
    foreach n [get_nets -quiet -segments -of_objects [get_pins -quiet -of_objects [get_cells $c]]] {
        if {![dict exists $ignored_nets [get_property NAME $n]]} {lappend ns $n}
    }
    set ends {}
    if {[llength $ns]} {set ends [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $ns] -filter {IS_PRIMITIVE}]}
    set neighbours {}; set owners {}
    foreach e [get_property NAME $ends] {
        if {[dict exists $glue_set $e]} {if {$e ne $c} {lappend neighbours $e}} else {
            set owner [assigned_group $e]
            if {$owner ne "FREE"} {lappend owners $owner}
        }
    }
    dict set adj $c [lsort -unique $neighbours]
    dict set touches $c [lsort -unique $owners]
}
set visited [dict create]
foreach c [dict keys $glue_set] {
    if {[dict exists $visited $c]} continue
    set queue [list $c]; set component {}; set owners {}
    while {[llength $queue]} {
        set e [lindex $queue 0]; set queue [lrange $queue 1 end]
        if {[dict exists $visited $e]} continue
        dict set visited $e 1
        lappend component $e
        set owners [concat $owners [dict get $touches $e]]
        set queue [concat $queue [dict get $adj $e]]
    }
    set owners [lsort -unique $owners]
    if {[llength $owners] == 1} {
        set owner [lindex $owners 0]
        set pb [expr {$owner eq "PW" ? "pb_pw" : "pb_dw"}]
        add_cells_to_pblock [get_pblocks $pb] [get_cells $component]
        if {$owner eq "PW"} {set pw_cells [concat $pw_cells $component]} else {set dw_cells [concat $dw_cells $component]}
        puts "FP_ROOT_COMPONENT $owner [llength $component] $component"
    } else {puts "FP_ROOT_COMPONENT FREE owners=$owners count=[llength $component] $component"}
}
