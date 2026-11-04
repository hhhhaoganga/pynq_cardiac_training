#!/bin/bash
# Restore this release onto a PYNQ-Z2 over the direct cable.
#   bash restore_board.sh [board_ip]
# Copies board_app/ and hand_pipeline_v3_20261010/ into /home/xilinx, installs the echo-demo
# and hand-sv units with only this release's drop-ins, then restarts in order.
set -euo pipefail
ip=${1:-169.254.1.99}
here=$(cd "$(dirname "$0")" && pwd)

tar czf /tmp/pynq_board.tgz -C "$here" board_app hand_pipeline_v3_20261010 deploy
scp /tmp/pynq_board.tgz "xilinx@$ip:/tmp/pynq_board.tgz"
ssh -t "xilinx@$ip" 'set -e; cd /tmp && rm -rf pynq_restore && mkdir pynq_restore && cd pynq_restore
  tar xzf /tmp/pynq_board.tgz
  sudo systemctl stop echo-demo hand-sv 2>/dev/null || true
  ts=$(date +%s)
  for d in board_app hand_pipeline_v3_20261010; do
    if [ -d /home/xilinx/$d ]; then sudo mv /home/xilinx/$d /home/xilinx/${d}_before_restore_$ts; fi
    sudo cp -a $d /home/xilinx/
  done
  for u in echo-demo hand-sv; do
    if [ -d /etc/systemd/system/$u.service.d ]; then
      sudo mv /etc/systemd/system/$u.service.d /home/xilinx/$u.service.d_before_restore_$ts
    fi
    sudo cp -a deploy/$u.service /etc/systemd/system/
    sudo cp -a deploy/$u.service.d /etc/systemd/system/
  done
  sudo systemctl daemon-reload
  sudo systemctl enable echo-demo.service
  sudo systemctl restart hand-sv; sleep 25; sudo systemctl restart echo-demo; sleep 5
  systemctl --no-pager is-active hand-sv echo-demo
  rm -rf /tmp/pynq_restore /tmp/pynq_board.tgz'
