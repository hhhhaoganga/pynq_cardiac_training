"""Snapshot sources, then validate RTL + AXI and synthesize that exact revision."""
import argparse, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

def main(name):
    root=Path(__file__).resolve().parent
    run=root/'runs'/name
    run.mkdir(parents=True,exist_ok=False)
    for d in ('rtl','tb','fixture'):shutil.copytree(root/d,run/d)
    for f in ('simulate.sh','simulate_axi.sh','simulate_arithmetic.sh','synth.tcl','compile_program.py'):shutil.copy2(root/f,run/f)
    hashes={str(p.relative_to(run)):hashlib.sha256(p.read_bytes()).hexdigest() for p in run.rglob('*') if p.is_file()}
    (run/'input_hashes.json').write_text(json.dumps(hashes,indent=2))
    status=dict(pid=os.getpid(),run=str(run),started=time.time(),stage='starting')
    def save():
        for p in (root/'validation_status.json',run/'status.json'):
            tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(status,indent=2));tmp.replace(p)
    try:
        for stage,cmd,log,marker in (
            ('arithmetic',['bash','simulate_arithmetic.sh'],'arithmetic/console.log','SV_QUANT_EDGE_PASS'),
            ('core_cosim',['bash','simulate.sh','0'],'sim/console.log','SV_KNOT_FULL_PASS'),
            ('axi_cosim',['bash','simulate_axi.sh','1'],'sim_axi/console.log','SV_KNOT_AXI_PASS'),
            ('synthesis',['/home/lizx/Xilinx/Vivado/2024.2/bin/vivado','-mode','batch','-nojournal','-source','synth.tcl','-log','synthesis/vivado.log'],'synthesis/console.log','SV_KNOT_OOC_DONE')):
            status['stage']=stage;save()
            (run/Path(log).parent).mkdir(exist_ok=True)
            with (run/(stage+'.launcher.log')).open('w') as f:
                rc=subprocess.run(cmd,cwd=run,stdout=f,stderr=subprocess.STDOUT).returncode
            # Vivado stdout is the synthesis report console; shell sim writes its own.
            if stage=='synthesis':shutil.copy2(run/(stage+'.launcher.log'),run/log)
            ok=rc==0 and marker in (run/log).read_text() if (run/log).exists() else False
            status[stage]=dict(returncode=rc,passed=ok)
            if not ok:raise RuntimeError(stage+' failed; inspect snapshot logs')
        status['stage']='review_required'
    except Exception as e:
        status.update(stage='failed',error=str(e))
    status['finished']=time.time();save()
    print(json.dumps(status,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('name');main(p.parse_args().name)
