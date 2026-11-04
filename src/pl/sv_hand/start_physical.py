import os
from pathlib import Path
import subprocess
R=Path(__file__).resolve().parent
assert not (R/'implementation').exists()
with (R/'implementation.launcher.log').open('x') as f:
    p=subprocess.Popen(['/home/lizx/.conda/envs/heart25d/bin/python','-u','run_physical_once.py'],cwd=R,
                       stdout=f,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
(R/'implementation.pid').write_text(str(p.pid));print(p.pid)
