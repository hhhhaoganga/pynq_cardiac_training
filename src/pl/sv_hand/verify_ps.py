"""C++ crop versus OpenCV; original integer tail versus independent IntRef.

CPU-host timing is recorded separately and cannot establish ARM or board fps.
"""
import ctypes as ct
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import time

import cv2
import numpy as np
import torch

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,'/home/lizx/knot_hand_20261002')
import nnp
from preprocess import RoiStager


def main():
    out=ROOT/'ps_validation';out.mkdir(exist_ok=True)
    p=nnp.read(ROOT/'models/landmark.nnp')
    mean=next(o for o in p.ops if o.type==nnp.MEAN)
    heads=[o for o in p.ops if o.type==nnp.FC_F]
    feature=p.tensors[mean.ins[0]]
    data=bytearray(struct.pack('<9i',0x314c5448,feature.h*feature.w,feature.c,int(feature.signed),*mean.e[:2],mean.lo,mean.hi,len(heads)))
    names=[]
    for h in heads:
        assert h.ins==[mean.out]
        data+=struct.pack('<i',h.cout)+h.w.astype('i1').tobytes()+h.bias.astype('<i4').tobytes()+h.deq.astype('<f4').tobytes()
        names.append(next((name for t,name in p.outputs if t==h.out),f'tensor_{h.out}'))
    (out/'tail.bin').write_bytes(data)
    (out/'tail.json').write_text(json.dumps(dict(heads=names,model_sha256=hashlib.sha256((ROOT/'models/landmark.nnp').read_bytes()).hexdigest()),indent=2))
    subprocess.run(['g++','-std=c++17','-O3','-Wall','-Wextra','-Werror','-fPIC','-shared',str(ROOT/'ps/hand_ps.cpp'),str(ROOT/'ps/ps_bridge.cpp'),'-o',str(out/'libhand_ps.so')],check=True)
    lib=ct.CDLL(str(out/'libhand_ps.so'))
    u8=np.ctypeslib.ndpointer(np.uint8,flags='C_CONTIGUOUS');f64=np.ctypeslib.ndpointer(np.float64,flags='C_CONTIGUOUS');u32=np.ctypeslib.ndpointer(np.uint32,flags='C_CONTIGUOUS')
    lib.hand_tail_create.argtypes=[ct.c_char_p];lib.hand_tail_create.restype=ct.c_void_p
    lib.hand_tail_destroy.argtypes=[ct.c_void_p]
    lib.hand_tail_run.argtypes=[ct.c_void_p,u8,f64]
    lib.hand_error.restype=ct.c_char_p
    handle=lib.hand_tail_create(str(out/'tail.bin').encode());assert handle,lib.hand_error()
    differences=[]
    for case in ['video','random']:
        for roi in range(2):
            src=ROOT/'fixtures'/case/f'reference{roi}'
            codes=np.fromfile(src/'tail_input.u8',np.uint8)
            actual=np.zeros(128,np.float64)
            assert lib.hand_tail_run(handle,codes,actual)==0,lib.hand_error()
            expected=json.loads((src/'tail_expected.json').read_text())
            # NNP computes a fourth (world-coordinate) FC head that the public
            # output list omits. Preserve and check it against the full graph.
            image=np.fromfile(src/'input.rgb',np.uint8).reshape(224,224,3)
            torch.set_num_threads(4)
            env=nnp.IntRef(p)(torch.from_numpy(image).permute(2,0,1)[None].long(),keep_all=True)['_env']
            for h,name in zip(heads,names):
                if name not in expected:expected[name]=env[h.out].flatten().tolist()
            expected=np.concatenate([expected[name] for name in names])
            np.testing.assert_array_equal(actual,expected)
            differences.append(dict(case=case,roi=roi,max_abs_error=float(np.abs(actual-expected).max())))
    # Extreme unsigned/signed feature codes verify rounding and accumulation
    # independently of four real model outputs.
    tail_cases=0;rng=np.random.default_rng(8)
    for trial in range(64):
        codes=rng.integers(0,256,(49,672),dtype=np.uint8) if trial>2 else np.full((49,672),[0,127,255][trial],np.uint8)
        x=codes.astype(np.int64)
        if feature.signed:x=np.where(x>=128,x-256,x)
        q=np.clip((x.sum(0)*mean.e[0]+(1<<(mean.e[1]-1)))>>mean.e[1],mean.lo,mean.hi)
        expected=np.concatenate([(h.w.astype(np.int64)@q+h.bias.astype(np.int64))*h.deq.astype(np.float64) for h in heads])
        actual=np.zeros(128,np.float64);assert lib.hand_tail_run(handle,codes,actual)==0
        np.testing.assert_array_equal(actual,expected);tail_cases+=1
    frame=rng.integers(0,256,(480,640,3),np.uint8)
    pixels=(frame[:,:,2].astype(np.uint32)<<16)|(frame[:,:,1].astype(np.uint32)<<8)|frame[:,:,0].astype(np.uint32)
    rois=[tuple(h['roi_used']) for h in json.loads((ROOT/'inputs/source.json').read_text())['hands']]
    rois += [(float(rng.uniform(-80,720)),float(rng.uniform(-80,560)),float(rng.uniform(72,600))) for _ in range(126)]
    dst=np.zeros((224,224,4),np.uint8)
    stager=RoiStager()
    for roi in rois:
        cx,cy,side=roi;s=224/side
        matrix=np.array([[s,0,112-s*cx],[0,s,112-s*cy]],np.float32)
        expected=cv2.warpAffine(frame,matrix,(224,224),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
        stager.prepare(frame,[roi],[dst])
        np.testing.assert_array_equal(dst[:,:,:3],expected[:,:,::-1]);assert not dst[:,:,3].any()
    t=time.perf_counter()
    for _ in range(200):stager.prepare(frame,[rois[0]],[dst])
    crop_ms=(time.perf_counter()-t)*1000/200
    t=time.perf_counter()
    for _ in range(1000):assert lib.hand_tail_run(handle,codes,actual)==0
    tail_ms=(time.perf_counter()-t)*1000/1000
    lib.hand_tail_destroy(handle)
    report=dict(passed=True,full_model_tail=differences,extreme_tail_cases=tail_cases,
                opencv_exact_crop_cases=len(rois),host_crop_ms=crop_ms,host_tail_ms=tail_ms,
                crop_backend='unchanged OpenCV '+cv2.__version__+' with reusable BGR scratch and direct RGBX destination',
                board_speed_measured=False,arm_neon_executed=False)
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))


if __name__=='__main__':main()
