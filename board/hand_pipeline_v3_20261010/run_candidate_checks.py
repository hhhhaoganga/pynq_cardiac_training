"""Detached board-only build/protocol checks, without changing running services."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent

def status(stage,**fields):
    data=dict(stage=stage,pid=os.getpid(),**fields)
    temp=ROOT/'candidate_checks.tmp';temp.write_text(json.dumps(data,indent=2)+'\n')
    temp.replace(ROOT/'candidate_checks.json');print(json.dumps(data),flush=True)

def execute(command,name):
    with (ROOT/name).open('w') as log:
        process=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    if process.returncode:raise RuntimeError(f'{name}: exit {process.returncode}')

def run():
    try:
        status('waiting_previous_build')
        start=time.monotonic()
        while True:
            listing=subprocess.check_output(['ps','-eo','args'],text=True).splitlines()
            if not any(line.strip().startswith('make -C app ') for line in listing):break
            if time.monotonic()-start>1800:raise RuntimeError('Earlier build still running after 30 minutes')
            time.sleep(5)
        # Power loss and the incorrect board clock make object mtimes unreliable.
        status('building');execute(['nice','-n','10','make','-C','app','-B','-j1'],'build_verified.log')
        status('building_protocol_probe')
        execute(['g++','-O2','-std=c++17','-fPIC','-shared','-I/usr/include/xrt','shared_bo.cpp','-lxrt_coreutil','-o','libhand_shared_bo.so'],'shared_bo_build.log')
        execute(['g++','-O2','-std=c++17','-Iapp/src','pool_protocol_probe.cpp','app/build/hand_accel.o','app/build/hw.o','-lxrt_coreutil','-lpthread','-o','pool_protocol_probe'],'protocol_build.log')
        status('protocol_test')
        execute([sys.executable,'test_shared_protocol.py'],'protocol_test.log')
        report=json.loads((ROOT/'shared_protocol_validation.json').read_text());assert report['passed']
        hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ('app/src',) for p in sorted((ROOT/folder).glob('*')) if p.is_file()}
        for name in ('app/echo_demo','libhand_shared_bo.so','shared_bo.cpp','shared_frames.py','board_runtime.py','board_service.py','pool_protocol_probe.cpp','test_shared_protocol.py'):
            hashes[name]=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
        (ROOT/'candidate_sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
        status('protocol_passed',validation=report,live_camera_validated=False,pl_crop_validated=False,deployed=False)
    except Exception as exc:status('failed',error=str(exc));traceback.print_exc();raise

if __name__=='__main__':
    if '--launch' in sys.argv:
        assert not (ROOT/'candidate_checks.json').exists(),'Inspect the existing run before a new launch'
        with (ROOT/'candidate_checks.launcher.log').open('x') as log:
            p=subprocess.Popen([sys.executable,'-u',str(Path(__file__).resolve())],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
        print(json.dumps(dict(pid=p.pid)))
    else:run()
