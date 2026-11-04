"""Freeze small sources/reports/fixtures after validation; exclude simulator databases."""
import hashlib
import json
from pathlib import Path
import tarfile
import time

r=Path(__file__).resolve().parent
assert json.loads((r/'status.json').read_text())['stage']=='rtl_and_ooc_complete'
assert json.loads((r/'detector_status.json').read_text())['stage']=='complete'
assert json.loads((r/'bandwidth_status.json').read_text())['stage']=='complete'
assert json.loads((r/'tracking_validation.json').read_text())['passed']
assert json.loads((r/'resource_review/review.json').read_text())['audit_passed']
files=[]
for p in r.iterdir():
    if p.is_file() and p.suffix in ('.py','.json','.md','.log','.console','.tcl'):files.append(p)
for directory in ['rtl','tb','ps','inputs','models','fixtures','synthesis','resource_review','ps_validation','tracking_reference']:
    for p in (r/directory).rglob('*'):
        if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.dcp','.so'):files.append(p)
for p in (r/'runs').glob('*/*'):
    if p.is_file() and p.suffix in ('.log','.sv','.json'):files.append(p)
manifest={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}
mf=r/'VALIDATION_SHA256.json';mf.write_text(json.dumps(manifest,indent=2)+'\n')
archive=r/'validation_release.tar.gz'
with tarfile.open(archive,'w:gz') as tar:
    for name in manifest:tar.add(r/name,arcname=name)
    tar.add(mf,arcname=mf.name)
report=dict(archive=archive.name,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),bytes=archive.stat().st_size,
            files=len(manifest),created=time.time(),physical_implementation_included=False)
(r/'validation_release.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
