"""Batch the two live tracks without changing the accepted tracking decisions.

Pass the existing TwoHandTracker class and a backend with detection(frame,area)
and landmarks(frame,rois). Recovery stays causal and is timed separately; it is
not reported as a normal 14fps frame or filled with old keypoints.
"""
from collections import Counter
import time


class BatchModels:
    def __init__(self,backend):
        self.backend=backend;self.calls=Counter();self.jobs=Counter();self.pending={}

    def prime(self,frame,tracks):
        self.pending.clear()
        live=sorted((t for t in tracks if not t['failures']),key=lambda t:-t['streak'])
        if not live:return
        rois=[t['roi'].copy() for t in live]
        observations=self.backend.landmarks(frame,rois)
        if len(observations)!=len(rois):raise RuntimeError('Incomplete fresh ROI batch')
        self.jobs['tracking_batches']+=1
        for roi,obs in zip(rois,observations):
            key=tuple(map(float,roi))
            # Equal ROIs are possible before duplicate suppression. Keep order.
            self.pending.setdefault(key,[]).append(obs)

    def landmark(self,frame,roi):
        self.calls['landmark']+=1
        key=tuple(map(float,roi))
        if self.pending.get(key):return self.pending[key].pop(0)
        self.jobs['recovery_roi_batches']+=1
        result=self.backend.landmarks(frame,[roi])
        if len(result)!=1:raise RuntimeError('Incomplete recovery ROI')
        return result[0]

    def detection(self,frame,region):
        self.calls['detector']+=1;self.jobs['detector_batches']+=1
        return self.backend.detection(frame,region)


class BatchedTracker:
    def __init__(self,tracker_class,backend,config=None):
        self.models=BatchModels(backend)
        self.tracker=tracker_class(self.models) if config is None else tracker_class(self.models,config)

    def step(self,frame,timestamp):
        start=time.perf_counter();before=self.models.calls.copy()
        self.models.prime(frame,self.tracker.tracks)
        result=self.tracker.step(frame,timestamp)
        if any(self.models.pending.values()):raise RuntimeError('Tracker skipped an expected ROI')
        result['wall_ms']=(time.perf_counter()-start)*1000
        result['recovery_frame']=self.models.calls['detector']>before['detector']
        return result
