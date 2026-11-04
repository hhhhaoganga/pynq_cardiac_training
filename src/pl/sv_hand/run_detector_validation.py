"""Additional existing-handdet verification on identical RTL; no synthesis/P&R."""
import json
from pathlib import Path
import re
import sys
import time
from run_validation import run,V
R=Path(__file__).resolve().parent
summary={}
try:
    (R/'detector_status.json').write_text(json.dumps(dict(stage='building_fixtures',updated=time.time())))
    run([sys.executable,R/'build_detector.py'],R,R/'detector_build.log')
    assert 'DETECTOR_FIXTURES_PASS' in (R/'detector_build.log').read_text()
    for case in ['video','random']:
        label='detector_'+case+'_axi';out=R/'runs'/label;out.mkdir(parents=True,exist_ok=False)
        fixture=R/'fixtures'/('detector_'+case)/'single';(out/'fixture').symlink_to(fixture,target_is_directory=True)
        info=json.loads((fixture/'program.json').read_text())
        (R/'detector_status.json').write_text(json.dumps(dict(stage='axi_validation',case=case,updated=time.time(),completed=summary),indent=2))
        run([V/'xvlog','--sv',*sorted((R/'rtl').glob('*.sv')),R/'tb/tb_axi.sv'],out,out/'compile.log')
        run([V/'xelab','tb_axi','-s','hand_sim','--mt','4'],out,out/'elaborate.log')
        run([V/'xsim','hand_sim','-runall','-testplusarg',f'PROGRAM={info["program_beat"]}','-testplusarg',f'WORDS={info["words"]}',
             '-testplusarg',f'CHECKS={len(info["checks"])}','-testplusarg','STALL=1'],out,out/'console.log')
        m=re.search(r'SV_HAND_AXI_PASS blocks=(\d+) cycles=(\d+)',(out/'console.log').read_text())
        if not m:raise RuntimeError('Missing detector pass marker: '+case)
        summary[case]=dict(blocks=int(m[1]),cycles=int(m[2]),conditional_ms_100MHz=int(m[2])/1e5)
    (R/'detector_status.json').write_text(json.dumps(dict(stage='complete',updated=time.time(),results=summary),indent=2))
except Exception as e:
    (R/'detector_status.json').write_text(json.dumps(dict(stage='failed',error=str(e),updated=time.time(),completed=summary),indent=2))
    raise
