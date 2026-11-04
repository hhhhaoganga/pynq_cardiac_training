"""Full original-model RTL validation, followed by OOC only. Stop on failure."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

ROOT=Path(__file__).resolve().parent
V=Path('/home/lizx/Xilinx/Vivado/2024.2/bin')


def status(stage,**kwargs):
    (ROOT/'status.json').write_text(json.dumps(dict(stage=stage,updated=time.time(),**kwargs),indent=2)+'\n')
    print(stage,kwargs,flush=True)


def run(cmd,cwd,log):
    with log.open('w') as f:p=subprocess.run([str(x) for x in cmd],cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
    if p.returncode:raise RuntimeError(f'{log}: exit {p.returncode}')


def main():
    results={}
    try:
        (ROOT/'validated_sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'rtl').glob('*.sv'))},indent=2))
        status('building_integer_fixtures')
        run([sys.executable,'build_fixtures.py','--training-root','/home/lizx/knot_hand_20261002'],ROOT,ROOT/'fixture_build.log')
        assert 'HAND_FIXTURES_PASS' in (ROOT/'fixture_build.log').read_text()
        cases=[('video_shared_core','video','shared','tb_knot',0),
               ('video_sequential_core','video','sequential','tb_knot',0),
               ('random_shared_core','random','shared','tb_knot',1),
               ('video_shared_axi','video','shared','tb_axi',1),
               ('random_shared_axi','random','shared','tb_axi',1),
               ('video_shared_axi_ideal','video','shared','tb_axi',0)]
        for label,case,mode,top,stall in cases:
            status('rtl_validation',case=label,completed=list(results))
            out=ROOT/'runs'/label;out.mkdir(parents=True,exist_ok=False)
            fixture=ROOT/'fixtures'/case/mode;(out/'fixture').symlink_to(fixture,target_is_directory=True)
            info=json.loads((fixture/'program.json').read_text())
            run([V/'xvlog','--sv',*sorted((ROOT/'rtl').glob('*.sv')),ROOT/'tb'/f'{top}.sv'],out,out/'compile.log')
            run([V/'xelab',top,'-s','hand_sim','--mt','4'],out,out/'elaborate.log')
            run([V/'xsim','hand_sim','-runall','-testplusarg',f'PROGRAM={info["program_beat"]}',
                 '-testplusarg',f'WORDS={info["words"]}','-testplusarg',f'CHECKS={len(info["checks"])}',
                 '-testplusarg',f'STALL={stall}'],out,out/'console.log')
            log=(out/'console.log').read_text()
            match=re.search(r'SV_HAND_(?:FULL|AXI)_PASS blocks=(\d+) cycles=(\d+)',log)
            if not match:raise RuntimeError(f'{label}: missing full pass marker')
            results[label]=dict(blocks=int(match[1]),cycles=int(match[2]),conditional_ms_100MHz=int(match[2])/1e5)
            (ROOT/'validation_summary.json').write_text(json.dumps(results,indent=2)+'\n')
        if results['video_shared_core']['cycles']>=results['video_sequential_core']['cycles']:
            raise RuntimeError('Interleaving did not improve full-model cycles')
        status('ooc_synthesis',validation=results)
        run([V/'vivado','-mode','batch','-nojournal','-nolog','-source',ROOT/'synth.tcl'],ROOT,ROOT/'synthesis.console')
        assert 'SV_KNOT_OOC_DONE' in (ROOT/'synthesis.console').read_text()
        status('rtl_and_ooc_complete',validation=results,physical_implementation=False,board_fps_verified=False)
    except Exception as e:
        status('failed',error=str(e),completed=results)
        traceback.print_exc()
        raise


if __name__=='__main__':main()
