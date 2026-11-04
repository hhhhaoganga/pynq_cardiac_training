"""Read-only snapshot of the currently deployed shared-frame release and assets."""
import hashlib,io,json,os,subprocess,sys,tarfile,traceback
from pathlib import Path
ROOT=Path('/home/xilinx/hand_shared_dma_release_20261008')
OUT=Path('/home/xilinx/hand_shared_dma_v1_20261008_board_snapshot.tar.gz')
def command(args):
    p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    return dict(returncode=p.returncode,output=p.stdout)
def main():
    assert not OUT.exists(),'Archive already exists; inspect before replacing'
    paths=[Path('/home/xilinx/board_app'),ROOT,Path('/home/xilinx/hand_release_20261008'),
           Path('/etc/systemd/system/echo-demo.service'),Path('/etc/systemd/system/hand-sv.service'),
           Path('/etc/systemd/system/echo-demo.service.d'),Path('/etc/systemd/system/hand-sv.service.d')]
    active=command(['systemctl','is-active','echo-demo','hand-sv']);assert active['returncode']==0
    ui_pid=int(subprocess.check_output(['systemctl','show','echo-demo','-p','MainPID','--value']))
    backend_pid=int(subprocess.check_output(['systemctl','show','hand-sv','-p','MainPID','--value']))
    assert Path(f'/proc/{ui_pid}/exe').resolve()==ROOT/'app/echo_demo'
    assert Path(f'/proc/{backend_pid}/cwd').resolve()==ROOT
    environment=dict(deployment='hand_shared_dma_v1_20261008',board_clock_unreliable=True,
        active=active,ui_pid=ui_pid,backend_pid=backend_pid,
        kernel=command(['uname','-a']),os_release=Path('/etc/os-release').read_text(),
        packages=command(['dpkg-query','-W']),
        effective_services=command(['systemctl','cat','echo-demo','hand-sv']),
        python=command([sys.executable,'-c','import sys,cv2,numpy;print(sys.version);print("cv2",cv2.__version__,"numpy",numpy.__version__)']),
        shared_libraries={n:command(['ldd',str(ROOT/n)]) for n in ['app/echo_demo','libhand_board.so','libhand_crop.so','libhand_shared_bo.so']},
        exclusions=['build object caches','__pycache__','redundant compressed archives','old firmware_bak_pre_jy62','archive_running.py and its live output'])
    entries={};members=[]
    for root in paths:
        for p in ([root] if root.is_file() else sorted(root.rglob('*'))):
            if not p.is_file():continue
            relative=p.relative_to(root) if p!=root else Path(p.name)
            if any(x in ('build','__pycache__','firmware_bak_pre_jy62') for x in relative.parts):continue
            if p.name.endswith(('.tgz','.tar.gz','.pyc')) or p.name.startswith('archive_running'):continue
            assert not p.is_symlink(),p
            name='board_payload/'+str(p).lstrip('/')
            members.append((p,name))
    with tarfile.open(OUT,'w:gz',compresslevel=1) as tar:
        for p,name in members:
            data=p.read_bytes();entries[name]=hashlib.sha256(data).hexdigest()
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=p.stat().st_mode&0o777;info.mtime=int(p.stat().st_mtime)
            tar.addfile(info,io.BytesIO(data))
        for name,data in [('board_environment.json',json.dumps(environment,indent=2).encode()),
                          ('BOARD_SHA256SUMS.txt',''.join(f'{h}  {n}\n' for n,h in sorted(entries.items())).encode())]:
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;tar.addfile(info,io.BytesIO(data))
    report=dict(passed=True,file=str(OUT),bytes=OUT.stat().st_size,files=len(entries),sha256=hashlib.sha256(OUT.read_bytes()).hexdigest(),services_left_running=True)
    (ROOT/'archive_running_result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report),flush=True)
if __name__=='__main__':
    try:main()
    except Exception as exc:
        (ROOT/'archive_running_result.json').write_text(json.dumps(dict(passed=False,error=str(exc)),indent=2)+'\n');traceback.print_exc();raise
