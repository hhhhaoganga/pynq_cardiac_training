"""One physical run of an exact reviewed SV snapshot. No strategy retries."""
import hashlib,json,os,re,shutil,subprocess,sys,time
from pathlib import Path

root=Path(__file__).resolve().parent
revision=sys.argv[1]
r=root/'runs'/revision
random_run=root/'runs'/(revision+'_random')
static=Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')
status=json.loads((r/'status.json').read_text())
assert status['stage']=='review_required'
assert all(status[k]['passed'] for k in ('arithmetic','core_cosim','axi_cosim','synthesis'))
assert json.loads((random_run/'status.json').read_text())['passed']
for name,expected in json.loads((r/'input_hashes.json').read_text()).items():
    assert hashlib.sha256((r/name).read_bytes()).hexdigest()==expected, name
for p in (r/'rtl').glob('*.sv'):
    assert p.read_bytes()==(random_run/'rtl'/p.name).read_bytes(),p.name
assert 'SV_KNOT_AUDIT_DONE' in (r/'audit/console.log').read_text()
timing=(r/'synthesis/timing.rpt').read_text()
wns=float(re.search(r'Slack \((?:MET|VIOLATED)\)\s*:\s*([-\d.]+)ns',timing)[1])
assert wns>=0, 'Fix known synthesis timing before routing'
axi=(r/'sim_axi/console.log').read_text()
cycles=int(re.search(r'SV_KNOT_AXI_PASS blocks=22 cycles=(\d+)',axi)[1])
assert cycles<=4200000, 'Insufficient 50ms frame budget'
row=next(s for s in (r/'synthesis/hierarchy.rpt').read_text().splitlines() if re.match(r'\| rm_cnn_top\s+\|',s))
values=[int(x.strip()) for x in row.split('|')[3:-1]]
lut,logic,lutram,srl,ff,bram36,bram18,dsp=values
assert lut<22572 and ff<21380 and bram36+bram18/2<78.5 and dsp<=88
out=r/'implementation'
out.mkdir(exist_ok=False)
for f in ('implement_once.tcl','write_bitstreams.tcl'):shutil.copy2(root/f,out/f)
sources=[r/'synthesis/knot_sv_synth.dcp',r/'audit/prepared.dcp',static,r/'audit.tcl',out/'implement_once.tcl',out/'write_bitstreams.tcl']
(out/'input_hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2))
state=dict(pid=os.getpid(),revision=revision,started=time.time(),stage='implementation',
           reviewed_cycles=cycles,reviewed_wns=wns,reviewed_resources=dict(LUT=lut,FF=ff,BRAM36=bram36+bram18/2,DSP=dsp))
def save():
    tmp=out/'status.tmp';tmp.write_text(json.dumps(state,indent=2));tmp.replace(out/'status.json')
def execute(script,args,label,marker):
    cmd=['/home/lizx/Xilinx/Vivado/2024.2/bin/vivado','-mode','batch','-nojournal','-source',str(out/script),'-log',str(out/(label+'.log')),'-tclargs',*[str(p) for p in args]]
    state['command']=cmd;save()
    with (out/(label+'.console')).open('w') as f:rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
    return rc==0 and marker in (out/(label+'.console')).read_text()
save()
try:
    if not execute('implement_once.tcl',[r/'audit/prepared.dcp',static,out],'implementation','SV_KNOT_IMPL_PASS'):
        raise RuntimeError('Implementation failed; diagnostics saved, no retry')
    state['stage']='bitstreams';save()
    if not execute('write_bitstreams.tcl',[out/'routed.dcp',out],'bitstreams','SV_KNOT_BITSTREAMS_DONE'):
        raise RuntimeError('Bitstream generation failed')
    (out/'SHA256SUMS.txt').write_text('\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name for p in sorted(out.iterdir()) if p.suffix in ('.bit','.bin'))+'\n')
    state['stage']='complete'
except Exception as e:state.update(stage='failed',error=str(e))
state['finished']=time.time();save()
print(json.dumps(state,indent=2))
