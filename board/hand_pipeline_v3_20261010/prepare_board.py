"""Stage the CPU-crop candidate and run isolated checks; never activates services."""
from pathlib import Path
import hashlib,json,os,shutil,signal,subprocess,sys,tarfile,time,traceback
ROOT=Path('/home/xilinx/hand_shared_dma_release_20261008')
BASE=Path('/home/xilinx/hand_release_20261008/runtime')
OLD=Path('/home/xilinx/hand_pl_crop_release_20261008/shared_dma')
ARCHIVE=Path('/home/xilinx/hand_shared_dma_sources.tgz')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def save(stage,**fields):
    data=dict(stage=stage,pid=os.getpid(),**fields);temp=ROOT/'preparation.tmp'
    temp.write_text(json.dumps(data,indent=2)+'\n');temp.replace(ROOT/'preparation.json');print(json.dumps(data),flush=True)

def execute(command,logname):
    with (ROOT/logname).open('w') as log:
        rc=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
    if rc:raise RuntimeError(f'{logname}: exit {rc}')

def earlier_make():
    for p in Path('/proc').glob('[0-9]*'):
        try:
            if (p/'comm').read_text().strip()=='make' and (p/'cwd').resolve()==OLD/'app':return True
        except (FileNotFoundError,ProcessLookupError,PermissionError):pass
    return False

def run():
    try:
        save('staging_original_runtime')
        assert sha(BASE/'dfx_full_hand_dual_roi_sv.bin')=='d4f26f768a869e6ef651f6171ce045ca8072b0c54170c29a27e7982bb2ffee74'
        shutil.copytree(BASE,ROOT,dirs_exist_ok=True)
        (ROOT/'baseline_reports').mkdir(exist_ok=True)
        for name in ('board_validation.json','board_camera_validation.json','ps_stage_profile.json'):
            if (ROOT/name).exists():shutil.move(ROOT/name,ROOT/'baseline_reports'/name)
        with tarfile.open(ARCHIVE) as tar:
            for item in tar.getmembers():
                destination=(ROOT/item.name).resolve()
                if not destination.is_relative_to(ROOT) or item.issym() or item.islnk():raise ValueError('Invalid source archive member')
            tar.extractall(ROOT)
        assert 'PLStager' not in (ROOT/'board_service.py').read_text()
        save('waiting_prior_app_build')
        started=time.monotonic()
        while earlier_make():
            if time.monotonic()-started>1800:raise TimeoutError('Prior app compilation exceeded 30 minutes')
            time.sleep(5)
        # Source archives carry the real date but the board clock is wrong.
        # Normalize local build mtimes, preserving content hashes in the report.
        for p in (ROOT/'app').rglob('*'):
            if p.is_file():p.touch()
        cache=[]
        headers=list((ROOT/'app/src').glob('*.hpp'))
        same_headers=all((OLD/'app/src'/p.name).exists() and sha(p)==sha(OLD/'app/src'/p.name) for p in headers)
        if same_headers:
            (ROOT/'app/build').mkdir(exist_ok=True)
            for p in (ROOT/'app/src').glob('*.cpp'):
                obj=OLD/'app/build'/(p.stem+'.o')
                if (OLD/'app/src'/p.name).exists() and sha(p)==sha(OLD/'app/src'/p.name) and obj.exists() and obj.stat().st_size>0:
                    shutil.copyfile(obj,ROOT/'app/build'/obj.name);cache.append(p.name)
        save('building',verified_reused_objects=cache)
        execute(['nice','-n','10','make','-C','app','-j1'],'build.log')
        execute(['g++','-O3','-std=c++17','-fPIC','-shared','-fno-fast-math','-ffp-contract=off','-mcpu=cortex-a9','-mfpu=neon','-mfloat-abi=hard','ps/accurate_crop.cpp','-o','libhand_crop.so'],'crop_build.log')
        execute(['g++','-O2','-std=c++17','-fPIC','-shared','-I/usr/include/xrt','shared_bo.cpp','-lxrt_coreutil','-o','libhand_shared_bo.so'],'shared_bo_build.log')
        execute(['g++','-O2','-std=c++17','-Iapp/src','pool_protocol_probe.cpp','app/build/hand_accel.o','app/build/hw.o','-lxrt_coreutil','-lpthread','-o','pool_protocol_probe'],'protocol_build.log')
        save('testing_cpu_coherence_and_protocol')
        execute([sys.executable,'test_shared_protocol.py'],'protocol_test.log')
        protocol=json.loads((ROOT/'shared_protocol_validation.json').read_text());assert protocol['passed']
        save('testing_crop_equivalence')
        execute([sys.executable,'test_xrgb_crop.py'],'xrgb_crop_test.log')
        crop=json.loads((ROOT/'xrgb_crop_validation.json').read_text());assert crop['passed'] and crop['cases']==128
        manifest={str(p.relative_to(ROOT)):sha(p) for p in sorted(ROOT.glob('*.py'))}
        for folder in ('app/src','ps'):
            manifest.update({str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/folder).glob('*')) if p.is_file()})
        for name in ('app/echo_demo','libhand_crop.so','libhand_shared_bo.so','dfx_full_hand_dual_roi_sv.bin','dfx_partial_hand_dual_roi_sv.bin'):
            manifest[name]=sha(ROOT/name)
        (ROOT/'candidate_sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
        save('isolated_checks_passed',protocol=protocol,crop=crop,deployed=False,live_camera_validated=False,model_unchanged=True)
    except Exception as exc:save('failed',error=str(exc));traceback.print_exc();raise

if __name__=='__main__':
    if '--launch' in sys.argv:
        ROOT.mkdir(exist_ok=True)
        assert not (ROOT/'preparation.json').exists(),'Inspect prior candidate before relaunch'
        # Cancel only our obsolete test supervisor; leave the useful app build
        # and all running user services alone.
        p=Path('/proc/2110/cmdline')
        if p.exists() and b'run_candidate_checks.py' in p.read_bytes():os.killpg(2110,signal.SIGTERM)
        with (ROOT/'preparation.launcher.log').open('x') as log:
            process=subprocess.Popen([sys.executable,'-u',str(Path(__file__).resolve())],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        print(json.dumps(dict(pid=process.pid,root=str(ROOT))))
    else:run()
