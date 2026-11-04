#!/bin/bash
set -e
cd /home/lizx/knot_hand_20261002
export PYTHONPATH=$PWD/pylib CUDA_VISIBLE_DEVICES=0 OMP_NUM_THREADS=4 PYTHONUNBUFFERED=1
export KNOT_SRC=$PWD/data/knot/edition3 KNOT_SPLIT=$PWD/data/knot/split_ed3c.json
PY=/home/lizx/.conda/envs/heart25d/bin/python
$PY -u experiments/resolution_20261007/train_resolution_ed3.py --task knot --height 256 --width 320 --stage float --init experiments/resolution_20261007/runs/256x320/float/best.pth --epochs 12 --lr 1e-4 --batch 32 --workers 6 --out runs_ed3c_dw3/float > runs_ed3c_dw3/float.log 2>&1
$PY -u experiments/resolution_20261007/train_resolution_ed3.py --task knot --height 256 --width 320 --stage qat --init runs_ed3c_dw3/float/best.pth --epochs 10 --lr 1e-4 --transition 6 --batch 32 --workers 6 --out runs_ed3c_dw3/qat > runs_ed3c_dw3/qat.log 2>&1
$PY -u knot_two_stage_eval.py --det experiments/resolution_20261007/runs/256x320/qat/best.pth runs_ed3c_dw3/qat/best.pth --cls runs_crop/qat_b/knot_cls.nnp --out runs_ed3c_dw3/two_stage_eval.json > runs_ed3c_dw3/eval.log 2>&1
echo RUN_DONE > runs_ed3c_dw3/DONE
