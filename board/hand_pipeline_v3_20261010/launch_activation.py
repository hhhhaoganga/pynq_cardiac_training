from pathlib import Path
import hashlib,json,subprocess,tarfile
ROOT=Path('/home/xilinx/hand_shared_dma_release_20261008')
assert json.loads((ROOT/'preparation.json').read_text())['stage']=='isolated_checks_passed'
assert not (ROOT/'activation_stage.txt').exists(),'Inspect existing activation first'
with tarfile.open(ROOT/'integration_update.tgz') as t:
    for item in t.getmembers():
        assert (ROOT/item.name).resolve().is_relative_to(ROOT) and not item.issym() and not item.islnk()
    t.extractall(ROOT)
manifest={}
for pattern in ['*.py','*.so','app/echo_demo','app/src/*','ps/*','validation_videos/*','dfx*bin']:
    for p in ROOT.glob(pattern):
        if p.is_file():manifest[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
(ROOT/'activation_source_sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
with (ROOT/'activation.launcher.log').open('x') as f:
    p=subprocess.Popen(['/bin/sh',str(ROOT/'activate_verified.sh')],cwd=ROOT,stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
print(json.dumps(dict(pid=p.pid,stage='activation_launched')))
