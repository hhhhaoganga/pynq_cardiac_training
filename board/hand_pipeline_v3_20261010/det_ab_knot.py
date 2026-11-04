"""Golden + A/B of detector packages on validation videos (services stopped). argv: package dirs."""
import json,os,sys,time
from pathlib import Path
import numpy as np,cv2
from board_runtime import ROOT,load_full,Package
import board_service
from lagged_tracking import LaggedTracker
from prior_tracking import PriorTracker
from tracker_core import TwoHandTracker
from validate_v3 import frames
cv2.setNumThreads(1);os.environ['HAND_PIPELINE']='2'
load_full();b=board_service.Backend();rep=[]
for tag,d in [('old',ROOT/'detector_backup_20261017'),('new',ROOT/'knotdet_staging')]:
    pk=d/'detector_video' if tag=='old' else d/'packages/detector_video'
    b.det=Package(pk,b.regs);b.scales=np.fromfile(d/'detector_dequant.f32',np.float32)
    g=b.det.golden();print(tag,'golden',json.dumps(g),flush=True)
    if tag=='new':
        r=Package(d/'packages/detector_random',b.regs).golden();print(tag,'golden_random',json.dumps(r),flush=True)
    for v in [ROOT/'knot_holdout/knot_video_20261017_135412.mp4']:
        for tname,cls in (('orig',TwoHandTracker),('prior',PriorTracker)):
            t=LaggedTracker(cls,b,lag=True);out=[]
            for i,ts,f in frames(v,12):
                r=t.push(f.copy(),ts,token=i)
                if r:out.append(r)
            out.append(t.flush())
            hands=np.array([len(r['hands']) for r in out]);ev=[e for r in out for e in r['events']]
            gaps=[e['gap_s'] for e in ev if e['kind']=='recovered']
            # Detector-only quality: boxes returned per detector call
            row=dict(det=tag,tracker=tname,video=v.name[-10:],two_hands=round(float((hands==2).mean()),3),
                     mean_hands=round(float(hands.mean()),3),detector=sum(r['calls'].get('detector',0) for r in out),
                     lost=sum(e['kind']=='lost' for e in ev),recovered=len(gaps),
                     gap_mean=round(float(np.mean(gaps)),3) if gaps else None)
            rep.append(row);print(json.dumps(row),flush=True)
b.close();(ROOT/'det_ab_knot.json').write_text(json.dumps(rep,indent=1))
print('DET_AB_DONE')
