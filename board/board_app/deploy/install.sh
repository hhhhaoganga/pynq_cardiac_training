#!/bin/bash
# On the board, as root: build echo_demo and install it as a boot service.
#   sudo bash /home/xilinx/board_app/deploy/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
for f in firmware/dfx_full_seg.bin firmware/dfx_partial_seg.bin firmware/dfx_partial_shape.bin; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done
sudo -u xilinx make -j2
install -m 644 deploy/echo-demo.service /etc/systemd/system/echo-demo.service
systemctl daemon-reload
systemctl enable echo-demo.service
systemctl restart echo-demo.service
sleep 3
systemctl --no-pager status echo-demo.service | head -12
