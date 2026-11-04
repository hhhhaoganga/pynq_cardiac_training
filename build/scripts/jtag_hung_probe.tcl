# Post-mortem JTAG probe for a hung board: target states, try to halt each
# A9 core and read its PC, and query PL configuration state. The board is
# already unresponsive, so halting the cores loses nothing.
connect
puts "== targets"
puts [targets]
foreach core {"ARM Cortex-A9 MPCore #0" "ARM Cortex-A9 MPCore #1"} {
    if {[catch {targets -set -filter [list name == $core]} err]} { puts "$core select failed: $err"; continue }
    if {[catch {stop} err]} { puts "$core stop failed: $err" }
    after 500
    if {[catch {puts "$core pc=[rrd pc]"} err]} { puts "$core rrd pc failed: $err" }
}
puts "== targets after stop"
puts [targets]
if {[catch {
    targets -set -nocase -filter {name =~ "xc7z020*"}
    puts "fpga state: [fpga -state]"
} err]} { puts "fpga state failed: $err" }
disconnect
puts "JTAG_HUNG_PROBE_DONE"
