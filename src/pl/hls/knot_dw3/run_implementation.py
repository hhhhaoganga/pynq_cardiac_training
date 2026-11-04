"""Run the reviewed checkpoint once; export only after implementation + RTL pass."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

here=Path(__file__).resolve().parent
out=here/'impl_20261007'
audit=here/'resource_review/audit'
static=Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')
if 'U_CAPACITY_PREFLIGHT_PASS' not in (here/'audit.log').read_text():
    raise SystemExit('Preflight did not pass')
if (here/'run/run.rc').read_text().strip() != '0' or '\nKNOT_MAC64_VALIDATION_PASS\n' not in (here/'run/console.log').read_text():
    raise SystemExit('RTL validation did not pass')
if json.loads((here/'evaluation_status.json').read_text())['stage'] != 'ready_for_resource_and_cycle_review':
    raise SystemExit('Evaluation incomplete')
# Ensure the reviewed source/config/fixtures have not changed since cosimulation.
for path, expected in json.loads((here/'input_hashes.json').read_text()).items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
        raise SystemExit('Reviewed input changed: '+path)
out.mkdir(exist_ok=False)
state={'pid':os.getpid(),'stage':'implementation','started':time.time()}
def save():
    temp=out/'status.tmp';temp.write_text(json.dumps(state,indent=2));temp.replace(out/'status.json')
def run(script,args,label):
    cmd=['/home/lizx/Xilinx/Vivado/2024.2/bin/vivado','-mode','batch','-nojournal',
         '-log',str(out/(label+'.log')),'-source',str(here/script),'-tclargs',*[str(x) for x in args]]
    state['command']=cmd;save()
    with (out/(label+'.console')).open('w') as log:
        r=subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT)
    return r.returncode,(out/(label+'.console')).read_text()
inputs=[audit/'prepared.dcp',here/'resource_review/synthesis/knot_synth.dcp',static,
        here/'implement_once.tcl',here/'floorplan.tcl',here/'fixtures/knot/knot_config.hpp',
        here/'cnn_engine.cpp',here/'cnn_engine.hpp']
(out/'input_hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},indent=2))
rc,log=run('implement_once.tcl',[audit/'prepared.dcp',static,out],'implementation')
if rc or '\nKNOT_IMPL_PASS\n' not in log:
    state.update(stage='failed',returncode=rc);save();raise SystemExit(1)
state['stage']='waiting_rtl_cosim';save()
rtl=here/'run'
while not (rtl/'run.rc').exists():
    time.sleep(15)
if (rtl/'run.rc').read_text().strip()!='0' or 'KNOT_MAC64_VALIDATION_PASS' not in (rtl/'console.log').read_text():
    state.update(stage='rtl_cosim_failed');save();raise SystemExit(1)
state['stage']='bitstreams';save()
rc,log=run('write_bitstreams.tcl',[out/'routed.dcp',out],'bitstreams')
ok=rc==0 and '\nKNOT_BITSTREAMS_DONE\n' in log
state.update(stage='complete' if ok else 'bitstream_failed',returncode=rc,finished=time.time());save()
if ok:
    (out/'SHA256SUMS.txt').write_text('\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name
        for p in sorted(out.iterdir()) if p.suffix in ('.bit','.bin'))+'\n')
raise SystemExit(0 if ok else 1)
