import json,time
import cv2,numpy as np
from board_service import Backend
from board_runtime import ROOT
b=Backend();f=cv2.imread(str(ROOT/'test_frame.png'));rois=json.loads((ROOT/'test_rois.json').read_text())
rows=[];p=b.dual
for _ in range(20):
    t0=time.perf_counter();b.stager.prepare(f,rois,p.input_views)
    t1=time.perf_counter();out=p.execute();t2=time.perf_counter()
    for x in out:b.tail.run(x)
    t3=time.perf_counter()
    rows.append(dict(crop_ms=(t1-t0)*1000,execute_ms=(t2-t1)*1000,tail_ms=(t3-t2)*1000,**p.last))
report={k:float(np.mean([r[k] for r in rows])) for k in rows[0]}
(ROOT/'ps_stage_profile.json').write_text(json.dumps(dict(means=report,rows=rows),indent=2))
print(json.dumps(report),flush=True)
