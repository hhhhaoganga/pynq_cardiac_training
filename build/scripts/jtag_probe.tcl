# Read-only JTAG probe: lists targets and reads the Zynq BOOT_MODE strap.
# Does not reset, halt or program anything.
connect
puts "== targets"
puts [targets]
if {[catch {
    targets -set -nocase -filter {name =~ "APU*"}
    set mode [mrd -value 0xF800025C]
    set strap [expr {$mode & 0x7}]
    set names {0 JTAG 1 QSPI 2 NOR 5 SD 4 NAND}
    set label [expr {[dict exists $names $strap] ? [dict get $names $strap] : "unknown"}]
    puts [format "BOOT_MODE=0x%08X strap=%d (%s)" $mode $strap $label]
} err]} { puts "BOOT_MODE read failed: $err" }
disconnect
puts "JTAG_PROBE_DONE"
