import hashlib,json,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent
revision=sys.argv[1]
reviewed=root/'runs'/revision
out=root/'runs'/(revision+'_random')
out.mkdir(exist_ok=False)
for d in ('rtl','tb'):shutil.copytree(reviewed/d,out/d)
shutil.copy2(reviewed/'simulate_axi.sh',out/'simulate_axi.sh')
base=root.parent/'hls_knot_dw3/mac64_256x320'
source=base/'fixtures/knot'
reference=out/'reference';reference.mkdir()
for f in ('checks.txt','knot_config.hpp','profile.json'):shutil.copy2(source/f,reference/f)
with (out/'reference_build.log').open('w') as log:
    subprocess.run(['g++','-std=c++14','-O2','-Wno-unknown-pragmas',
        '-I/home/lizx/Xilinx/Vitis/2024.2/include','-I'+str(base),'-I'+str(source),
        str(root/'tests/reference_fixture.cpp'),str(base/'cnn_engine.cpp'),'-o',str(out/'reference_model')],check=True,stdout=log,stderr=subprocess.STDOUT)
with (out/'reference.log').open('w') as log:subprocess.run([str(out/'reference_model'),str(source),str(reference)],check=True,stdout=log,stderr=subprocess.STDOUT)
subprocess.run([sys.executable,str(root/'compile_program.py'),str(reference),str(out/'fixture')],check=True)
hashes={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for d in ('rtl','tb','fixture','reference') for p in (out/d).rglob('*') if p.is_file()}
hashes['oracle_cnn_engine.cpp']=hashlib.sha256((base/'cnn_engine.cpp').read_bytes()).hexdigest()
hashes['oracle_cnn_engine.hpp']=hashlib.sha256((base/'cnn_engine.hpp').read_bytes()).hexdigest()
(out/'input_hashes.json').write_text(json.dumps(hashes,indent=2))
with (out/'launcher.log').open('w') as log:r=subprocess.run(['bash','simulate_axi.sh','1'],cwd=out,stdout=log,stderr=subprocess.STDOUT)
text=(out/'sim_axi/console.log').read_text() if (out/'sim_axi/console.log').exists() else ''
ok=r.returncode==0 and 'SV_KNOT_AXI_PASS' in text
(out/'status.json').write_text(json.dumps(dict(passed=ok,returncode=r.returncode,oracle='validated HLS C integer model, new random RGB input'),indent=2))
if not ok:raise SystemExit(1)
print('SV_SECOND_INPUT_PASS')
