"""One physical feasibility attempt for the validated hand SVH1 candidate.

63.74 ms is a conditional bus-model result; P&R does not accept board 14fps.
No retries, changed directives, static edits, or board programming.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

R=Path(__file__).resolve().parent
V=Path('/home/lizx/Xilinx/Vivado/2024.2/bin')
STATIC=Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    state=json.loads((R/'status.json').read_text());assert state['stage']=='rtl_and_ooc_complete'
    assert len(state['validation'])==6 and all(x['blocks']==38 for x in state['validation'].values())
    for name,digest in json.loads((R/'validated_sources.json').read_text()).items():assert sha(R/name)==digest,name
    detector=json.loads((R/'detector_status.json').read_text());assert detector['stage']=='complete'
    assert all(x['blocks']==23 for x in detector['results'].values())
    bandwidth=json.loads((R/'bandwidth_status.json').read_text())
    assert bandwidth['stage']=='complete' and bandwidth['cycles']<=6500000
    for name in ['tracking_validation.json','driver_validation.json','ps_validation/results.json']:
        assert json.loads((R/name).read_text())['passed'],name
    review=json.loads((R/'resource_review/review.json').read_text())
    assert review['audit_passed'] and review['ooc_wns_ns']>=0
    assert review['static_sha256']==sha(STATIC)
    out=R/'implementation';out.mkdir(exist_ok=False)
    for name in ['implement_once.tcl','write_bitstreams.tcl']:
        s=(R.parent/'sv_knot'/name).read_text().replace('SV_KNOT','SV_HAND').replace('knot_sv.bit','hand_dual_roi_sv.bit')
        (out/name).write_text(s)
    sources=[R/'synthesis/knot_sv_synth.dcp',R/'resource_review/prepared.dcp',STATIC,
             out/'implement_once.tcl',out/'write_bitstreams.tcl',R/'resource_review/audit.tcl']
    for directory in ['rtl','tb','ps']:
        target=out/'validated_sources'/directory;target.mkdir(parents=True)
        for p in (R/directory).iterdir():
            if p.is_file():shutil.copy2(p,target/p.name);sources.append(target/p.name)
    (out/'input_hashes.json').write_text(json.dumps({str(p):sha(p) for p in sources},indent=2))
    state=dict(pid=os.getpid(),started=time.time(),stage='implementation',reviewed_resources=review['resources'],
               reviewed_ooc_wns_ns=review['ooc_wns_ns'],conditional_400MB_cycles=bandwidth['cycles'],
               board_fps_verified=False,board_programming=False,automatic_retry=False)
    def save():
        tmp=out/'status.tmp';tmp.write_text(json.dumps(state,indent=2)+'\n');tmp.replace(out/'status.json')
    def execute(script,args,label,marker):
        cmd=[str(V/'vivado'),'-mode','batch','-nojournal','-source',str(out/script),'-log',str(out/(label+'.log')),
             '-tclargs',*[str(p) for p in args]]
        state['command']=cmd;save()
        with (out/(label+'.console')).open('w') as f:rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
        if rc or marker not in (out/(label+'.console')).read_text():raise RuntimeError(label+' failed; no retry')
    save()
    try:
        execute('implement_once.tcl',[R/'resource_review/prepared.dcp',STATIC,out],'implementation','SV_HAND_IMPL_PASS')
        assert sha(STATIC)==review['static_sha256']
        state['stage']='bitstreams';save()
        execute('write_bitstreams.tcl',[out/'routed.dcp',out],'bitstreams','SV_HAND_BITSTREAMS_DONE')
        (out/'SHA256SUMS.txt').write_text('\n'.join(sha(p)+'  '+p.name for p in sorted(out.iterdir()) if p.suffix in ('.bit','.bin'))+'\n')
        state['stage']='complete'
    except Exception as e:state.update(stage='failed',error=str(e))
    state['finished']=time.time();save();print(json.dumps(state,indent=2))


if __name__=='__main__':main()
