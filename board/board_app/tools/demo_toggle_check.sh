#!/bin/sh
# Footer switch check: turn the local demo off and confirm the worker goes
# idle, turn it back on and confirm it works again. Run as root, no host connected.
FIFO=/tmp/echo_demo_input
PID=$(pidof echo_demo)
send() { timeout 2 sh -c "echo '$1' > $FIFO" || echo "fifo write timed out: $1"; }
# utime + stime (ticks) of the named thread
ticks() {
    for t in /proc/$PID/task/*; do
        [ "$(cat $t/comm)" = "$1" ] && awk '{print $14 + $15}' $t/stat
    done
}
busy() {  # ticks of thread $1 over 3 s
    a=$(ticks "$1"); sleep 3; b=$(ticks "$1"); echo $((b - a))
}

send "move 640 360"
send "click 472 28"                   # seg tab (pins the demo, playback at 30 fps)
sleep 3
on1=$(busy worker)
send "click 1200 704"                 # 本地演示：开 -> 关
sleep 1.5
echo /tmp/ui_demo_off.png > /tmp/echo_demo_shot
off=$(busy worker)
send "click 1200 704"                 # 关 -> 开
sleep 1.5
on2=$(busy worker)
echo /tmp/ui_demo_on.png > /tmp/echo_demo_shot
sleep 0.5
send "click 472 28"                   # unpin: alternate modules again
echo "worker ticks/3s: on $on1, off $off, on again $on2"
# Local demo at 30 fps: the worker only submits / polls (~10 ticks per 3 s); off it just waits.
if [ "$off" -le 1 ] && [ "$on1" -ge 5 ] && [ "$on2" -ge 5 ]; then echo DEMO_TOGGLE_PASS; else echo DEMO_TOGGLE_FAIL; fi
