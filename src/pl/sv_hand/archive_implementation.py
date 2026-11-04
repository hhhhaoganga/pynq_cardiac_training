import hashlib
import json
from pathlib import Path
import tarfile
import time

r=Path(__file__).resolve().parent
out=r/'implementation'
state=json.loads((out/'status.json').read_text())
assert state['stage'] in ['complete','failed']
for line in (out/'SHA256SUMS.txt').read_text().splitlines() if state['stage']=='complete' else []:
    digest,name=line.split();assert hashlib.sha256((out/name).read_bytes()).hexdigest()==digest,name
files=[p for p in out.rglob('*') if p.is_file() and not any(v in p.parts for v in ['.Xil','__pycache__'])]
manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
mf=out/'IMPLEMENTATION_SHA256.json';mf.write_text(json.dumps(manifest,indent=2)+'\n')
archive=r/'implementation_release.tar.gz'
with tarfile.open(archive,'w:gz') as tar:
    for name in manifest:tar.add(out/name,arcname=name)
    tar.add(mf,arcname=mf.name)
meta=dict(archive=archive.name,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),bytes=archive.stat().st_size,
          files=len(manifest),created=time.time(),terminal_stage=state['stage'])
(r/'implementation_release.json').write_text(json.dumps(meta,indent=2)+'\n');print(meta)
