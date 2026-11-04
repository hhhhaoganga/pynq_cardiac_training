"""Task-scoped transfer/status; no board access or physical implementation."""
import argparse
from pathlib import Path
import shlex
import subprocess
import tarfile

HERE=Path(__file__).resolve().parent
REMOTE='/home/lizx/knot_hand_20261002/integration_knot_dw3/pynq_dfx/'+HERE.name
OPTIONS=['-F','D:/PLD/.ssh/config','-i','D:/PLD/.ssh/codex_lizx_nopass_ed25519','-o','UserKnownHostsFile=D:/PLD/.ssh/known_hosts','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15']


def remote(code):
    subprocess.run(['ssh',*OPTIONS,'lizx','python3 -c '+shlex.quote(code)],check=True)


def main():
    ap=argparse.ArgumentParser();ap.add_argument('mode',choices=['upload','start','status','command','download']);ap.add_argument('args',nargs='*');a=ap.parse_args()
    if a.mode=='upload':
        remote(f'from pathlib import Path;Path({REMOTE!r}).mkdir(exist_ok=True)')
        archive=HERE/'sources.tar.gz'
        with tarfile.open(archive,'w:gz') as tar:
            for p in sorted(HERE.iterdir()):
                if p.is_file() and (p.suffix in ('.py','.tcl','.md','.cpp','.hpp') or p.name=='source_baseline.json'):tar.add(p,arcname=p.name)
                elif p.name in ('rtl','tb','inputs','models','ps','tracking_reference'):tar.add(p,arcname=p.name)
        subprocess.run(['scp',*OPTIONS,str(archive),'lizx:'+REMOTE+'/sources.tar.gz'],check=True)
        remote(f"import tarfile;tarfile.open({REMOTE!r}+'/sources.tar.gz').extractall({REMOTE!r},filter='data')")
    elif a.mode=='start':
        remote(f'''from pathlib import Path
import subprocess,os,json
r=Path({REMOTE!r})
assert not (r/'status.json').exists(), 'Existing run: inspect before any restart'
env=os.environ.copy();env['PYTHONPATH']='/home/lizx/knot_hand_20261002/pylib:/home/lizx/knot_hand_20261002';env['OMP_NUM_THREADS']='4'
with (r/'launcher.log').open('x') as f:
 p=subprocess.Popen(['/home/lizx/.conda/envs/heart25d/bin/python','-u','run_validation.py'],cwd=r,env=env,stdout=f,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
(r/'run.pid').write_text(str(p.pid));print(json.dumps({{'pid':p.pid,'root':str(r)}}))
''')
    elif a.mode=='status':
        remote(f'''from pathlib import Path
r=Path({REMOTE!r})
for name in ['status.json','validation_summary.json','detector_status.json','tracking_validation.json']:
 p=r/name
 if p.exists():print(name,p.read_text())
for p in [r/'launcher.log',r/'fixture_build.log']+sorted(r.glob('runs/*/console.log')):
 if p.exists():print(str(p.relative_to(r)), '\\n'.join(p.read_text(errors='replace').splitlines()[-5:]))
if (r/'run.pid').exists():
 pid=int((r/'run.pid').read_text());print('supervisor',pid,'alive',Path('/proc/'+str(pid)).exists())
''')
    elif a.mode=='command':subprocess.run(['ssh',*OPTIONS,'lizx',' '.join(a.args)],check=True)
    else:
        for name in a.args:
            p=HERE/name;p.parent.mkdir(exist_ok=True,parents=True)
            subprocess.run(['scp',*OPTIONS,'lizx:'+REMOTE+'/'+name,str(p)],check=True)


if __name__=='__main__':main()
