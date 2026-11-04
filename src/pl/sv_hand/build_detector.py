"""Original detector on the same SVH1 core, including its one spatial stripe."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import cv2
import numpy as np
import torch

R=Path(__file__).resolve().parent
sys.path.insert(0,'/home/lizx/knot_hand_20261002')
import nnp
from compile_single import compile_fixture


def main():
    # Ensure adding detector stripes did not change any landmark instruction.
    for case in ['video','random']:
        target=R/'detector_review'/f'landmark_regression_{case}'
        compile_fixture(R/'fixtures'/case/'reference0',target)
        for name in ['memory.bin','program.txt']:
            assert (target/name).read_bytes()==(R/'fixtures'/case/'single0'/name).read_bytes(),name
    sp=importlib.util.spec_from_file_location('hand_detector_compiler',R.parent/'hls_cnn/compile_nnp.py')
    comp=importlib.util.module_from_spec(sp);sys.modules[sp.name]=comp;sp.loader.exec_module(comp)
    # Descriptor generation describes the unsplit logical row; the SV compiler
    # proves each emitted stripe fits physical 512-vector memories.
    comp.LIMITS.update(lb_slot=640,pin=512,dwb=512,outb=256,outh=64,resb=512)
    torch.set_num_threads(4)
    model=R/'models/handdet.nnp'
    assert hashlib.sha256(model.read_bytes()).hexdigest()=='dadbaeaeb1e414cfbb837d8e692d5f15bfb28911a3c63eb4c4c7064a06bf08be'
    p=nnp.read(model);ref=nnp.IntRef(p);order,mid=comp.split_wide(p,comp.group(p))
    blob,addresses,descs,use=comp.compile_program(p,order)
    cap=cv2.VideoCapture('/home/lizx/knot_hand_20261002/experiments/shared_pose_20261008/videos/video_20261008_123417_000029.mp4')
    cap.set(cv2.CAP_PROP_POS_FRAMES,30);ok,frame=cap.read();cap.release();assert ok
    canvas=np.full((256,320,3),114,np.uint8);canvas[38:218]=cv2.resize(frame[120:480],(320,180),interpolation=cv2.INTER_AREA)
    video=cv2.cvtColor(canvas,cv2.COLOR_BGR2RGB)
    for case,img in [('video',video),('random',np.random.default_rng(602).integers(0,256,(256,320,3),np.uint8))]:
        env=ref(torch.from_numpy(img).permute(2,0,1)[None].long(),keep_all=True)['_env']
        for dst,src in mid.items():env[dst]=env[src]
        init,gold=bytearray(blob),bytearray(blob)
        for t,addr in addresses.items():
            data=comp.tensor_image(p,env,t);gold[addr:addr+len(data)]=data
            if t==p.input:init[addr:addr+len(data)]=data
        src=R/'fixtures'/('detector_'+case)/'reference';src.mkdir(parents=True,exist_ok=True)
        (src/'mem_init.bin').write_bytes(init);(src/'golden.bin').write_bytes(gold)
        lines=[f'{len(order)} {len(blob)}']+[f'{i} {addresses[b.out]} {comp.tensor_bytes(p.tensors[b.out],False)} t{b.out}' for i,b in enumerate(order)]
        (src/'checks.txt').write_text('\n'.join(lines)+'\n')
        out=src.parent/'single';compile_fixture(src,out)
        size=(out/'memory.bin').stat().st_size
        padded=gold+bytes(size-len(gold))
        (out/'golden.hex').write_text(''.join(f'{v[0]:016x}\n' for v in struct.iter_unpack('<Q',padded)))
        info=json.loads((out/'program.json').read_text());info['output']['valid_channels']=5
        (out/'program.json').write_text(json.dumps(info,indent=2)+'\n')
    print('DETECTOR_FIXTURES_PASS',len(order))


if __name__=='__main__':main()
