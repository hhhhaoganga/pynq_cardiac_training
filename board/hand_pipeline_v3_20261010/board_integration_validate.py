"""Exclusive-RP validation against the deployed BGR/NEON software path."""
import ctypes as C
import hashlib
import importlib.util
import json
import time
from pathlib import Path
import cv2
import numpy as np
from board_runtime import ROOT
from board_service import Backend
from batched_tracking import BatchedTracker
from tracker_core import TwoHandTracker

BASE=Path('/home/xilinx/hand_release_20261008/runtime')

class OriginalStager:
    def __init__(self):
        self.lib=C.CDLL(str(BASE/'libhand_crop.so'))
        self.lib.hand_crop.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_double,C.c_double,C.c_double,C.c_void_p]
    def prepare(self,frame,rois,destinations):
        assert frame.flags.c_contiguous and frame.shape[2]==3
        for roi,dst in zip(rois,destinations):
            assert self.lib.hand_crop(frame.ctypes.data,frame.shape[1],frame.shape[0],*map(float,roi),dst.ctypes.data)==0

def plain(value):
    if isinstance(value,dict):return {k:plain(v) for k,v in value.items() if k!='wall_ms'}
    if isinstance(value,(list,tuple)):return [plain(v) for v in value]
    if isinstance(value,np.ndarray):return value.tolist()
    if isinstance(value,np.generic):return value.item()
    return value

def main():
    cv2.setNumThreads(1)
    report=dict(passed=False,scope='original PL; BGR baseline versus shared XRGB PS preprocessing',cases=[])
    try:
        spec=importlib.util.spec_from_file_location('original_service',BASE/'board_service.py')
        original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
        baseline=original.Backend();baseline.stager=OriginalStager()
        candidate=Backend()
        frame=cv2.imread(str(ROOT/'test_frame.png'));assert frame is not None
        xrgb=cv2.cvtColor(frame,cv2.COLOR_BGR2BGRA)
        rois=json.loads((ROOT/'test_rois.json').read_text())
        old=baseline.landmarks(frame,rois);new=candidate.landmarks(xrgb,rois)
        assert plain(old)==plain(new),'Original landmark points/confidences changed'
        report['landmark_observations']=plain(new)
        for region in [(0,120,640,480),(0,0,640,480),(17,83,503,467)]:
            a=baseline.detection(frame,region);old_input=baseline.det.input_views[0].copy()
            b=candidate.detection(xrgb,region)
            np.testing.assert_array_equal(old_input,candidate.det.input_views[0])
            assert plain(a)==plain(b),'Detector observations changed'
        report['detector_regions_exact']=3
        left=BatchedTracker(TwoHandTracker,baseline);right=BatchedTracker(TwoHandTracker,candidate)
        for i in range(16):
            a=left.step(frame,i/14);b=right.step(xrgb,i/14)
            assert plain(a)==plain(b),f'Tracker decisions/points differ at {i}'
            report['cases'].append(dict(index=i,hands=len(b['hands']),confirmed=sum(h['confirmed'] for h in b['hands']),recovery=b['recovery_frame']))
        report['dual_benchmark']=[]
        for i in range(20):
            candidate.reset_stats();start=time.perf_counter();candidate.landmarks(xrgb,rois)
            report['dual_benchmark'].append(dict(total_ms=(time.perf_counter()-start)*1000,**candidate.stats))
        videos=sorted((ROOT/'validation_videos').glob('*.mp4'))
        assert len(videos)==2,'Both original unannotated videos are required'
        report['video_comparisons']=[]
        for video in videos:
            a=BatchedTracker(TwoHandTracker,baseline);b=BatchedTracker(TwoHandTracker,candidate)
            cap=cv2.VideoCapture(str(video));assert cap.isOpened()
            fps=cap.get(cv2.CAP_PROP_FPS);index=0;sample=0;two=0
            while True:
                ok,f=cap.read()
                if not ok:break
                if index==int(np.ceil(sample*fps/14-1e-9)):
                    old=a.step(f,index/fps);new=b.step(cv2.cvtColor(f,cv2.COLOR_BGR2BGRA),index/fps)
                    assert plain(old)==plain(new),f'{video.name} frame {index}: changed tracker/points'
                    two+=sum(h['confirmed'] for h in new['hands'])==2;sample+=1
                index+=1
            cap.release();assert sample>0
            report['video_comparisons'].append(dict(video=video.name,source_frames=index,sampled_frames=sample,both_confirmed=two,exact=True,sha256=hashlib.sha256(video.read_bytes()).hexdigest()))
            print(json.dumps(report['video_comparisons'][-1]),flush=True)
        report['passed']=True
    finally:
        (ROOT/'integration_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(passed=True,dual_backend_mean_ms=np.mean([r['total_ms'] for r in report['dual_benchmark']]),fixed_frame_cases=len(report['cases']),videos=len(videos))),flush=True)

if __name__=='__main__':main()
