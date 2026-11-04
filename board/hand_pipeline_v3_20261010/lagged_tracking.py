"""Cross-frame pipelining for the unchanged TwoHandTracker (scheme 3).

lag=False: prefetch frame k with the ROIs left by step k-1, then step k.
           Decisions are identical to BatchedTracker (used as a plumbing check).
lag=True:  prefetch frame k+1 with the ROIs left by step k-1 *before* step k,
           so the PL works on frame k+1 while the CPU runs tails/tracker for k.
           The ROI is one step stale; results are returned one request late.

The backend provides landmark_async(frame, roi) -> handle with result(),
and detection(frame, region). Prefetched observations are keyed by the track
object, so the tracker receives an observation whose roi_used is the stale ROI.
"""
from collections import Counter
import dataclasses
import os
import time
import numpy as np


class LaggedModels:
    def __init__(self,backend):
        self.backend=backend;self.calls=Counter();self.jobs=Counter()
        self.tracker=None;self.prefetched=[];self.retry=False

    def landmark(self,frame,roi):
        self.calls['landmark']+=1
        for i,(track,handle) in enumerate(self.prefetched):
            # The tracker passes track['roi'] itself; identity finds the caller.
            if track['roi'] is roi and any(t is track for t in self.tracker.tracks):
                del self.prefetched[i]
                obs=handle.result()
                # Stale crop failed: retry once with the current ROI (costs one landmark).
                if self.retry and self.tracker.quality(obs,track.get('obs')) is not None:
                    self.jobs['stale_retry']+=1
                    obs=self.backend.landmark_async(frame,roi).result()
                    if self.tracker.quality(obs,track.get('obs')) is None:self.jobs['stale_retry_ok']+=1
                return obs
        self.jobs['fresh_roi']+=1
        return self.backend.landmark_async(frame,roi).result()

    def detection(self,frame,region):
        self.calls['detector']+=1;self.jobs['detector_batches']+=1
        return self.backend.detection(frame,region)


class LaggedTracker:
    def __init__(self,tracker_class,backend,lag=True,config=None,predict=None,grow=None,retry=None):
        self.models=LaggedModels(backend);self.lag=lag
        # LAG_PREDICT/LAG_GROW/LAG_RETRY: 0 disables. Only meaningful with lag=True.
        self.predict=float(os.environ.get('LAG_PREDICT','0')) if predict is None else predict
        self.grow=float(os.environ.get('LAG_GROW','0')) if grow is None else grow
        self.models.retry=lag and (os.environ.get('LAG_RETRY','1')!='0' if retry is None else retry)
        if not lag:self.predict=0.0
        self.tracker=tracker_class(self.models) if config is None else tracker_class(self.models,config)
        # LAG_RETRY_S: re-detect interval after a lost hand (tracker default 0.35 s).
        retry_s=os.environ.get('LAG_RETRY_S','0.15') if lag else None
        if retry_s and config is None:self.tracker.cfg=dataclasses.replace(self.tracker.cfg,retry_s=float(retry_s))
        self.models.tracker=self.tracker;self.max_side=self.tracker.cfg.max_side
        self.failure_reasons=Counter()
        self.carried=None  # (frame, timestamp, prefetched, token) awaiting its step

    def predicted_roi(self,track):
        # The ROI is one step stale: extrapolate the centre by the last step's motion
        # and widen by that motion so the hand stays inside the crop.
        roi=track['roi'].copy();last=track.get('_lag_prev')
        track['_lag_prev']=(track['id'],track['streak'],roi[:2].copy())
        if not self.predict or last is None or last[0]!=track['id'] or track['streak']<2 or last[1]!=track['streak']-1:
            return roi
        v=roi[:2]-last[2];speed=float(np.linalg.norm(v))
        if speed>0.5*roi[2]:v*=0.5*roi[2]/speed;speed=0.5*roi[2]
        roi[:2]+=self.predict*v;roi[2]=min(self.max_side,roi[2]+self.grow*speed)
        return roi

    def prefetch(self,frame):
        live=sorted((t for t in self.tracker.tracks if not t['failures']),key=lambda t:-t['streak'])
        return [(t,self.models.backend.landmark_async(frame,self.predicted_roi(t))) for t in live]

    def _step(self,item):
        frame,timestamp,prefetched,token=item
        start=time.perf_counter();before=self.models.calls.copy()
        self.models.prefetched=list(prefetched)
        try:
            result=self.tracker.step(frame,timestamp)
        finally:
            # Lost/duplicate tracks skip their prefetch; still wait for the PL.
            for _,handle in self.models.prefetched:handle.result()
            self.models.prefetched=[]
        result['wall_ms']=(time.perf_counter()-start)*1000
        result['recovery_frame']=self.models.calls['detector']>before['detector']
        result['token']=token
        self.failure_reasons.update(f['reason'] for f in result['failures'] if f['id'] is not None)
        return result

    def push(self,frame,timestamp,token=None):
        """Feed frame k; return the finished result (k-1 when lagging, k otherwise) or None."""
        if not self.lag:
            return self._step((frame,timestamp,self.prefetch(frame),token))
        prefetched=self.prefetch(frame)
        previous,self.carried=self.carried,(frame,timestamp,prefetched,token)
        return self._step(previous) if previous else None

    def flush(self):
        """Finish the carried frame (offline replay)."""
        previous,self.carried=self.carried,None
        return self._step(previous) if previous else None

    def drop(self):
        """Discard the carried frame after its PL work completes (reset/mode switch)."""
        previous,self.carried=self.carried,None
        if previous:
            for _,handle in previous[2]:handle.result()
