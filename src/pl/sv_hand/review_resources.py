"""Read actual full-core resources and audit the unchanged original static shell."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import time
from run_validation import run,V

R=Path(__file__).resolve().parent
STATIC=Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')


def main():
    status=json.loads((R/'status.json').read_text());assert status['stage']=='rtl_and_ooc_complete'
    for name,expected in json.loads((R/'validated_sources.json').read_text()).items():
        assert hashlib.sha256((R/name).read_bytes()).hexdigest()==expected,name
    out=R/'resource_review';out.mkdir(exist_ok=True)
    assert not (out/'prepared.dcp').exists(), 'An audit result already exists'
    report=(R/'synthesis/utilization.rpt').read_text()
    def metric(name):
        pattern=r'\|\s*'+re.escape(name)+r'\*?\s*\|\s*([\d.]+)'
        m=re.search(pattern,report);assert m,name;return float(m[1])
    resources={k:metric(k) for k in ['Slice LUTs','Slice Registers','Block RAM Tile','DSPs']}
    timing=(R/'synthesis/timing.rpt').read_text()
    slack=re.search(r'Slack \((?:MET|VIOLATED)\)\s*:\s*([-\d.]+)ns',timing)
    assert slack
    result=dict(resources=resources,ooc_wns_ns=float(slack[1]),physical_implementation=False,board_fps_verified=False)
    assert resources['Slice LUTs']<35200 and resources['Block RAM Tile']<=100 and resources['DSPs']<=180
    before=hashlib.sha256(STATIC.read_bytes()).hexdigest()
    shutil.copy2(R.parent/'sv_knot/audit.tcl',out/'audit.tcl')
    run([V/'vivado','-mode','batch','-nojournal','-nolog','-source',out/'audit.tcl','-tclargs',R/'synthesis/knot_sv_synth.dcp',STATIC,out],out,out/'console.log')
    assert 'SV_KNOT_AUDIT_DONE' in (out/'console.log').read_text()
    assert hashlib.sha256(STATIC.read_bytes()).hexdigest()==before
    result.update(static_sha256=before,audit_passed=True,finished=time.time())
    (out/'review.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))


if __name__=='__main__':main()
