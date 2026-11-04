"""Build an isolated, hash-manifested board release from verified artifacts."""
import ast
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tarfile
import numpy as np

R=Path(__file__).resolve().parent
B=R/'board_release';B.mkdir(exist_ok=True)
F=R/'diagnostics/validation/fixtures'
for name,src in [('dual_video','video/shared'),('dual_random','random/shared'),
                 ('single_video','video/single0'),('detector_video','detector_video/single'),
                 ('detector_random','detector_random/single')]:
    d=B/'packages'/name;d.mkdir(parents=True,exist_ok=True);s=F/src
    shutil.copy2(s/'memory.bin',d/'memory.bin')
    if (s/'golden.bin').exists():shutil.copy2(s/'golden.bin',d/'golden.bin')
    else:(d/'golden.bin').write_bytes(b''.join(struct.pack('<Q',int(x,16)) for x in (s/'golden.hex').read_text().split()))
    m=json.loads((s/'program.json').read_text());m['abi']='SVH1';m['memory_sha256']=hashlib.sha256((d/'memory.bin').read_bytes()).hexdigest()
    (d/'program.json').write_text(json.dumps(m,indent=2)+'\n')
for name in ['board_runtime.py','board_validate.py','board_service.py','preprocess.py','batched_tracking.py']:
    if (R/name).exists():shutil.copy2(R/name,B/name)
for name in ['hand_ps.hpp','hand_ps.cpp','ps_bridge.cpp','board_bridge.cpp','accurate_crop.cpp']:shutil.copy2(R/'ps'/name,B/name)
for name in ['hw.hpp','hw.cpp']:shutil.copy2(R.parent/'board_app/src'/name,B/name)
for name in ['tail.bin','tail.json']:shutil.copy2(R/'diagnostics/validation/ps_validation'/name,B/name)
for name in ['dfx_full_hand_dual_roi_sv.bin','dfx_partial_hand_dual_roi_sv.bin']:
    shutil.copy2(R/'diagnostics/implementation'/name,B/name)
# Export only the unchanged tracker logic, excluding Torch/reference/video CLI.
source=(R/'tracking_reference/track_two_hands.py').read_text();tree=ast.parse(source)
names={'Config','bbox','iou','roi_from_box','clipped_region','TwoHandTracker'}
parts=['from collections import Counter\nfrom dataclasses import dataclass\nimport math\nimport numpy as np\n']
for node in tree.body:
    if getattr(node,'name',None) in names:
        start=min([node.lineno]+[x.lineno for x in getattr(node,'decorator_list',[])])
        parts.append('\n'.join(source.splitlines()[start-1:node.end_lineno]))
(B/'tracker_core.py').write_text('\n\n'.join(parts)+'\n')
# Read NNP serialization without importing the Torch inference implementation.
def ops(path):
    b=path.read_bytes();nt,no,_,nout=struct.unpack_from('<4I',b,4);pos=20+36*nout+24*nt;result=[]
    for _ in range(no):
        h=struct.unpack_from('<16i',b,pos);pos+=64;ty,_,_,_,k,_,dw,_,_,_,_,ci,co,*_=h;o={'header':h}
        if ty in (1,2,7):
            n=co*ci if ty==7 else k*k*co if dw else co*k*k*ci
            o['w']=np.frombuffer(b,'i1',n,pos).copy();pos+=n+(-n%4)
            o['bias']=np.frombuffer(b,'<i4',co,pos).copy();pos+=4*co
            if ty==1:pos+=8*co
            else:o['deq']=np.frombuffer(b,'<f4',co,pos).copy();pos+=4*co
        result.append(o)
    assert pos==len(b);return result
det=ops(R/'models/handdet.nnp');head=[o for o in det if o['header'][0]==2][-1]
head['deq'].tofile(B/'detector_dequant.f32')
lm=ops(R/'models/landmark.nnp');mean=next(o['header'] for o in lm if o['header'][0]==5);heads=[o for o in lm if o['header'][0]==7]
rng=np.random.default_rng(8);features=[np.full((49,672),v,np.uint8) for v in (0,127,255)]
features += [rng.integers(0,256,(49,672),np.uint8) for _ in range(61)]
for case in ['video','random']:
    for roi in (0,1):features.append(np.fromfile(F/case/f'reference{roi}/tail_input.u8',np.uint8).reshape(49,672))
signed=struct.unpack_from('<i',(B/'tail.bin').read_bytes(),12)[0];expected=[]
for x in features:
    x=x.astype(np.int64)
    if signed:x=np.where(x>=128,x-256,x)
    q=np.clip((x.sum(0)*mean[13]+(1<<(mean[14]-1)))>>mean[14],mean[9],mean[10])
    expected.append(np.concatenate([(o['w'].reshape(-1,672).astype(np.int64)@q+o['bias'])*o['deq'].astype(np.float64) for o in heads]))
np.stack(features).tofile(B/'tail_cases.u8');np.stack(expected).tofile(B/'tail_expected.f64')
make='g++ -std=c++17 -O3 -ffp-contract=off -fPIC -shared -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -I/usr/include/xrt hw.cpp hand_ps.cpp ps_bridge.cpp board_bridge.cpp accurate_crop.cpp -lxrt_coreutil -lpthread -o libhand_board.so\n'
(B/'build.sh').write_bytes(('set -eu\ncd /home/xilinx/hand_release_20261008/runtime\n'+make).encode())
with (B/'build.sh').open('ab') as f:f.write(b'g++ -std=c++17 -O3 -ffp-contract=off -fPIC -shared -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard accurate_crop.cpp -o libhand_crop.so\n')
manifest={str(p.relative_to(B)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(B.rglob('*')) if p.is_file() and p.name!='manifest.json'}
(B/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
archive=R/'board_release.tar.gz'
with tarfile.open(archive,'w:gz') as t:t.add(B,arcname='runtime')
print(json.dumps({'files':len(manifest),'archive':str(archive),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}))
