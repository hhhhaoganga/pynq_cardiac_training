import json,time,argparse
import cv2
import numpy as np
from board_runtime import ROOT,AccurateStager
from board_service import Backend
from tracker_core import TwoHandTracker
from batched_tracking import BatchedTracker

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--crop-only',action='store_true');args=parser.parse_args()
    fixtures=np.load(ROOT/'crop_cases.npz');rois=fixtures['rois'];frames=fixtures['frames'];expected=fixtures['expected']
    stage=AccurateStager();dst=np.empty((224,224,4),np.uint8);deltas=[]
    for i,roi in enumerate(rois):
        stage.prepare(frames[i%len(frames)],[roi],[dst]);delta=dst[:,:,:3][:,:,::-1].astype(int)-expected[i].astype(int)
        deltas.append(dict(changed=int(np.count_nonzero(delta)),max_abs=int(abs(delta).max())))
    report=dict(crop_cases=len(rois),crop_deltas=deltas,crop_exact=all(x['changed']==0 for x in deltas))
    (ROOT/'board_camera_validation.json').write_text(json.dumps(report,indent=2))
    assert report['crop_exact'],report
    if args.crop_only:
        print(json.dumps(report));return
    backend=Backend();frame=cv2.imread(str(ROOT/'test_frame.png'));rs=json.loads((ROOT/'test_rois.json').read_text());bench=[]
    for _ in range(20):
        backend.reset_stats();start=time.perf_counter();out=backend.landmarks(frame,rs)
        bench.append(dict(ms=(time.perf_counter()-start)*1000,**backend.stats))
    tracker=BatchedTracker(TwoHandTracker,backend);records=[]
    for i in range(8):records.append(tracker.step(frame,i/14))
    report.update(dual_camera_benchmark=bench,example_observations=out,tracking_records=records,passed=True)
    (ROOT/'board_camera_validation.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(crop_exact=True,cases=len(rois),dual_camera_mean_ms=np.mean([x['ms'] for x in bench]),visible_hands=[len(r['hands']) for r in records])),flush=True)
if __name__=='__main__':main()
