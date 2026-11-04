"""Compare batched original-model tracking with the accepted serial tracker.

Both recorded clips are evaluated, every selected 14Hz frame in time order.
This is an equivalence test, not newly labelled hand-pose accuracy or board fps.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys
import time

import cv2
import numpy as np
import torch

R=Path(__file__).resolve().parent
sys.path.insert(0,'/home/lizx/knot_hand_20261002')
sys.path.insert(0,str(R/'tracking_reference'))
from track_two_hands import TwoHandTracker,bbox
from check_video_baseline import detect,codes,roi_affine,crop,apply_affine,nnp
from batched_tracking import BatchedTracker


class Backend:
    def __init__(self):
        self.refs={name:nnp.IntRef(nnp.read(R/'models'/f'{name}.nnp')) for name in ['landmark','handdet']}
    def detection(self,frame,region):return detect(self.refs['handdet'],frame,region)
    def landmarks(self,frame,rois):
        matrices=[roi_affine(*roi,0,224) for roi in rois]
        batch=torch.cat([codes(crop(frame,m,224)) for m in matrices])
        output=self.refs['landmark'](batch)
        results=[]
        for i,(roi,m) in enumerate(zip(rois,matrices)):
            xy=output['landmarks'][i].float().numpy().reshape(21,3)[:,:2]
            points=apply_affine(cv2.invertAffineTransform(m),xy)
            results.append(dict(points=points.tolist(),box=bbox(points).tolist(),presence=float(output['presence_logit'][i].sigmoid().item()),
                                handedness_raw=float(output['handedness_logit'][i].sigmoid().item()),roi_used=np.asarray(roi).tolist()))
        return results


class Serial:
    def __init__(self,backend):self.backend=backend;self.calls=Counter()
    def detection(self,frame,region):self.calls['detector']+=1;return self.backend.detection(frame,region)
    def landmark(self,frame,roi):self.calls['landmark']+=1;return self.backend.landmarks(frame,[roi])[0]


def main():
    torch.set_num_threads(4)
    start=time.time();results=[]
    videos=Path('/home/lizx/knot_hand_20261002/experiments/shared_pose_20261008/videos')
    for path in sorted(videos.glob('*.mp4')):
        backend=Backend();serial=TwoHandTracker(Serial(backend));batch=BatchedTracker(TwoHandTracker,backend)
        cap=cv2.VideoCapture(str(path));fps=cap.get(cv2.CAP_PROP_FPS);total=int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        # Identical causal sampling to the accepted track_two_hands.run().
        selected=np.ceil(np.arange(0,total/fps,1/14)*fps-1e-8).astype(int)
        indices=set(selected[selected<total].tolist())
        count=0;two_hands=0
        for frame_index in range(total):
            ok,frame=cap.read();assert ok
            if frame_index not in indices:continue
            a=serial.step(frame,frame_index/fps);b=batch.step(frame,frame_index/fps)
            b.pop('wall_ms');b.pop('recovery_frame')
            assert a==b,dict(video=path.name,frame=frame_index,a=a,b=b)
            count+=1;two_hands+=len(a['hands'])==2
            if count%30==0:print(path.name,'equivalent_frames',count,flush=True)
        cap.release()
        results.append(dict(video=path.name,frames=count,two_hand_frames=two_hands,calls=dict(serial.models.calls),
                            batch_jobs=dict(batch.models.jobs),exact_decisions_and_points=True))
    assert len(results)==2
    report=dict(passed=True,results=results,seconds=time.time()-start,board_speed_measured=False,ground_truth_accuracy_measured=False,
                model_sha256={name:hashlib.sha256((R/'models'/f'{name}.nnp').read_bytes()).hexdigest() for name in ['landmark','handdet']})
    (R/'tracking_validation.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))


if __name__=='__main__':main()
