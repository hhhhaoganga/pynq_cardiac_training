"""Overlap actual synthesis/resource audit with the already-running RTL cosim."""
import json
import os
from pathlib import Path
import subprocess
import time

H = Path(__file__).resolve().parent
B = H.parent
state = json.loads((H/'evaluation_status.json').read_text())
state.update(pid=os.getpid(), resumed_for_parallel_resource_review=True)

def save(**kw):
    state.update(kw)
    p = H/'evaluation_status.tmp'
    p.write_text(json.dumps(state,indent=2))
    p.replace(H/'evaluation_status.json')

def run(stage, script, args, marker):
    out = H/'resource_review'/stage
    out.mkdir(parents=True,exist_ok=False)
    cmd = ['/home/lizx/Xilinx/Vivado/2024.2/bin/vivado','-mode','batch','-nojournal',
           '-log',str(out/'vivado.log'),'-source',str(script),'-tclargs',*map(str,args)]
    save(stage=stage,command=cmd)
    with (H/(stage+'.log')).open('w') as log:
        rc = subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT).returncode
    (H/(stage+'.rc')).write_text(str(rc))
    if rc or marker not in (H/(stage+'.log')).read_text():
        raise RuntimeError(f'{stage} failed, rc={rc}')

try:
    assert 'Finished Command csynth_design' in (H/'run/console.log').read_text()
    run('synthesis',B/'synth_ooc.tcl',[H/'hls_project/solution1/syn/verilog',H/'resource_review/synthesis'],
        'KNOT_OOC_SYNTH_DONE')
    static = Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')
    run('audit',B/'audit_u_capacity.tcl',[H/'resource_review/synthesis/knot_synth.dcp',static,
        H/'resource_review/audit',H/'floorplan.tcl'],'U_CAPACITY_PREFLIGHT_PASS')
    save(stage='waiting_rtl_cosim')
    while not (H/'run/run.rc').exists():
        time.sleep(15)
    assert (H/'run/run.rc').read_text().strip()=='0', 'HLS/cosim failed'
    assert 'KNOT_MAC64_VALIDATION_PASS' in (H/'run/console.log').read_text()
    save(stage='ready_for_resource_and_cycle_review',finished=time.time(),
         note='No physical implementation started; actual Slice packing and board20fps unverified.')
except Exception as exc:
    save(failed_stage=state['stage'],stage='failed',reason=str(exc),finished=time.time())
    raise
