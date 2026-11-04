from pathlib import Path
import json
import shutil

import cv2
import numpy as np

r=Path(__file__).resolve().parent
project=r.parents[1]
source=project/'hand_landmark/experiments/roi_video_20261008/tracking_v1/video_20261008_123417_000029_track_14fps.json'
report=json.loads(source.read_text())
record=next(x for x in report['records'] if len(x['hands'])==2)
print('Selected record keys',list(record))
video=project/'knot_data/videos'/report['summary']['video']
cap=cv2.VideoCapture(str(video))
index=record.get('frame_index',record.get('frame',record.get('source_frame')))
assert index is not None,record.keys()
cap.set(cv2.CAP_PROP_POS_FRAMES,index);ok,frame=cap.read();cap.release();assert ok
(r/'inputs').mkdir(exist_ok=True)
for i,hand in enumerate(record['hands']):
    cx,cy,side=hand['roi_used'];scale=224/side
    matrix=np.array([[scale,0,112-scale*cx],[0,scale,112-scale*cy]],np.float32)
    crop=cv2.warpAffine(frame,matrix,(224,224),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
    cv2.imwrite(str(r/'inputs'/f'roi{i}.png'),crop)
    (r/'inputs'/f'roi{i}.rgb').write_bytes(cv2.cvtColor(crop,cv2.COLOR_BGR2RGB).tobytes())
(r/'inputs/source.json').write_text(json.dumps(dict(source=str(source),frame_index=index,hands=record['hands']),indent=2))
(r/'models').mkdir(exist_ok=True)
for name in ['landmark','handdet']:
    shutil.copy2(r.parent/'board_app/data/nn'/f'{name}.nnp',r/'models'/f'{name}.nnp')
(r/'tb').mkdir(exist_ok=True)
for name in ['tb_knot','tb_axi']:
    s=(r.parent/'sv_knot/tb'/f'{name}.sv').read_text()
    s=s.replace('mem[0:399999],golden[0:208799]','mem[0:1499999],golden[0:1499999]')
    s=s.replace('400000','1500000').replace('checked!=22','checked!=expected_checks')
    s=s.replace('SV_KNOT_', 'SV_HAND_').replace('53564b31','53564831')
    s=s.replace('integer stall=0,','integer expected_checks=38,words;\n    integer stall=0,') if name=='tb_knot' else s.replace('integer rleft=0,','integer expected_checks=38,words;\n    integer rleft=0,')
    s=s.replace('if($value$plusargs("STALL=%d",stall))begin end','if($value$plusargs("STALL=%d",stall))begin end\n        if($value$plusargs("CHECKS=%d",expected_checks))begin end\n        if(!$value$plusargs("WORDS=%d",words))$fatal(1,"WORDS required");')
    s=s.replace('$readmemh("fixture/memory.hex",mem)','$readmemh("fixture/memory.hex",mem,0,words-1)')
    s=s.replace('$readmemh("fixture/golden.hex",golden)','$readmemh("fixture/golden.hex",golden,0,words-1)')
    if name=='tb_axi':
        s=s.replace('integer ar_bursts=0,', 'integer read_beats=0,write_beats=0;\n    integer ar_bursts=0,')
        s=s.replace('rptr<=rptr+1;', 'read_beats<=read_beats+1;rptr<=rptr+1;')
        s=s.replace('mem[wptr]<=M_AXI_MEM_wdata;', 'write_beats<=write_beats+1;mem[wptr]<=M_AXI_MEM_wdata;')
        s=s.replace('$display("SV_HAND_AXI_PASS', '$display("AXI_TRAFFIC read_beats=%0d write_beats=%0d",read_beats,write_beats);\n        $display("SV_HAND_AXI_PASS')
    else:
        # Fail immediately if an expanded PW array outruns narrow writeback.
        s=s.replace('if(!reset&&busy)state_cycles', 'if(!reset&&dut.pw_done&&((dut.c[7]==2&&dut.head_left>1)||(dut.c[7]!=2&&dut.drain_phase!=0)))$fatal(1,"PW writeback overwrite");\n        if(!reset&&busy)state_cycles')
    (r/'tb'/f'{name}.sv').write_text(s,newline='\n')
shutil.copy2(r.parent/'sv_knot/synth.tcl',r/'synth.tcl')
