import json
import os
from pathlib import Path
import subprocess

r=Path(__file__).resolve().parent
jobs={}
env=os.environ.copy();env['PYTHONPATH']='/home/lizx/knot_hand_20261002/pylib:/home/lizx/knot_hand_20261002';env['OMP_NUM_THREADS']='4'
for label,script in [('detector','run_detector_validation.py'),('tracking','verify_tracking.py')]:
    with (r/(label+'.launcher.log')).open('x') as f:
        p=subprocess.Popen(['/home/lizx/.conda/envs/heart25d/bin/python','-u',script],cwd=r,env=env,
                           stdout=f,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
    jobs[label]=p.pid
(r/'additional_pids.json').write_text(json.dumps(jobs,indent=2));print(jobs)
