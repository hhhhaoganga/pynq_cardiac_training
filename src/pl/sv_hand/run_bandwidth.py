"""Bound the data channel to one beat/two cycles (400 MB/s at 100MHz).

Still a bus model, not a measurement of the active board or DMA contention.
"""
import json
from pathlib import Path
import re
import time
from run_validation import run,V
R=Path(__file__).resolve().parent
try:
    out=R/'runs/video_shared_axi_400MB';out.mkdir(parents=True,exist_ok=False)
    fixture=R/'fixtures/video/shared';(out/'fixture').symlink_to(fixture,target_is_directory=True)
    s=(R/'tb/tb_axi.sv').read_text().replace('module tb_axi;', 'module tb_axi_budget;')
    s=s.replace('M_AXI_MEM_wready=wleft!=0&&', 'M_AXI_MEM_wready=wleft!=0&&!wall_cycles[0]&&')
    s=s.replace('read_pending<=!stall||random_state[11:9]!=0;', 'read_pending<=wall_cycles[0]&&(!stall||random_state[11:9]!=0);')
    s=s.replace('else if(rleft!=0&&!read_pending&&', 'else if(rleft!=0&&!read_pending&&wall_cycles[0]&&')
    (out/'tb_axi_budget.sv').write_text(s)
    info=json.loads((fixture/'program.json').read_text())
    (R/'bandwidth_status.json').write_text(json.dumps(dict(stage='running',updated=time.time())))
    run([V/'xvlog','--sv',*sorted((R/'rtl').glob('*.sv')),out/'tb_axi_budget.sv'],out,out/'compile.log')
    run([V/'xelab','tb_axi_budget','-s','hand_sim','--mt','4'],out,out/'elaborate.log')
    run([V/'xsim','hand_sim','-runall','-testplusarg',f'PROGRAM={info["program_beat"]}',
         '-testplusarg',f'WORDS={info["words"]}','-testplusarg','CHECKS=38','-testplusarg','STALL=1'],out,out/'console.log')
    m=re.search(r'SV_HAND_AXI_PASS blocks=(\d+) cycles=(\d+)',(out/'console.log').read_text())
    if not m:raise RuntimeError('400 MB/s model did not pass')
    result=dict(stage='complete',updated=time.time(),blocks=int(m[1]),cycles=int(m[2]),conditional_ms_100MHz=int(m[2])/1e5,
                payload_limit_MB_s=400,random_channel_stalls=True,board_speed_measured=False)
    (R/'bandwidth_status.json').write_text(json.dumps(result,indent=2));print(result)
except Exception as e:
    (R/'bandwidth_status.json').write_text(json.dumps(dict(stage='failed',updated=time.time(),error=str(e)),indent=2));raise
