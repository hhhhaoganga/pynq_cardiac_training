#!/bin/sh
# Gate for the camera page detection (step P0): switches to the camera tab,
# runs knot mode and then hand mode, and checks the journal for finished
# inferences of both. Screenshots land in /tmp/cam_knot.png, /tmp/cam_hand.png.
# Run as root on the board:  sudo sh tools/cam_det_check.sh
I=/tmp/echo_demo_input
send() { timeout 2 sh -c "echo $1 > $I"; }

send "move 300 300"
sleep 0.3
send "click 586 28"        # tab: camera (4 tabs since 2026-10-20)
sleep 2
for mode in knot hand; do
    if [ "$mode" = knot ]; then send "click 1050 357"; else send "click 1184 357"; fi
    echo "CAM_CHECK: $mode mode, waiting for two logged frames"
    n=0
    for i in $(seq 1 24); do          # up to 4 minutes: PS inference under full load is slow
        sleep 10
        n=$(journalctl -u echo-demo --since "-5min" --no-pager 2>/dev/null | grep -c "detect: $mode frame")
        [ "$n" -ge 2 ] && break
    done
    echo "CAM_CHECK: $mode logged frames: $n"
    [ "$n" -ge 2 ] || { echo "CAM_DET_CHECK_FAIL ($mode)"; exit 1; }
    timeout 2 sh -c "echo /tmp/cam_$mode.png > /tmp/echo_demo_shot"
    sleep 3
done
send "click 930 357"       # back to 关闭: inference costs both cores, leave it off
journalctl -u echo-demo --since "-10min" --no-pager 2>/dev/null | grep "detect: " | tail -4
echo CAM_DET_CHECK_PASS
