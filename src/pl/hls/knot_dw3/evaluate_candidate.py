"""One evaluation chain; no placement/routing, no retry, no board access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
PROJECT = BASE.parents[1]
TRAIN = Path('/home/lizx/knot_hand_20261002/experiments/resolution_20261007')
RUN = TRAIN/'runs/256x320'
STATE = {'pid': os.getpid(), 'started': time.time(), 'stage': 'waiting_qat'}
ENV = dict(os.environ, CUDA_VISIBLE_DEVICES='1',
           PYTHONPATH='/home/lizx/knot_hand_20261002/pylib', OMP_NUM_THREADS='4', MKL_NUM_THREADS='4')

def save(**updates):
    STATE.update(updates)
    p = HERE/'evaluation_status.tmp'
    p.write_text(json.dumps(STATE, indent=2))
    p.replace(HERE/'evaluation_status.json')

def run(stage, cmd, cwd=HERE, marker=None):
    save(stage=stage, command=list(map(str, cmd)))
    with (HERE/(stage+'.log')).open('w') as log:
        rc = subprocess.run(list(map(str, cmd)), cwd=cwd, env=ENV,
                            stdout=log, stderr=subprocess.STDOUT).returncode
    (HERE/(stage+'.rc')).write_text(str(rc))
    if rc or (marker and marker not in (HERE/(stage+'.log')).read_text()):
        raise RuntimeError(f'{stage} failed; exit={rc}; see {stage}.log')

def vivado(stage, script, args, marker):
    out = HERE/'resource_review'/stage
    out.mkdir(parents=True, exist_ok=False)
    run(stage, ['/home/lizx/Xilinx/Vivado/2024.2/bin/vivado', '-mode', 'batch', '-nojournal',
                '-log', out/'vivado.log', '-source', script, '-tclargs', *args], out, marker)

try:
    save()
    while not (RUN/'qat/results.json').exists():
        pid = json.loads((RUN/'status.json').read_text())['pid']
        if not Path(f'/proc/{pid}').exists():
            raise RuntimeError('QAT process exited without results.json')
        time.sleep(15)
    qp = json.loads((RUN/'qat/results.json').read_text())
    fp = json.loads((RUN/'float/results.json').read_text())['metrics']
    ctl = json.loads((TRAIN/'runs/320x416/qat/results.json').read_text())['metrics']
    limits = {'mAP50': .01, 'mAP50_95': .03, 'AP50_single': .02, 'AP50_square': .02, 'AP50_triple': .02}
    drops = {k: fp[k]-qp['metrics'][k] for k in limits}
    comparison = {'qat': qp, 'accepted_float': fp, 'full_resolution_qat': ctl,
                  'additional_quantization_drops': drops,
                  'drops_vs_full_resolution_qat': {k:ctl[k]-qp['metrics'][k] for k in limits},
                  'additional_quantization_limits': limits,
                  'float_resolution_tradeoff_accepted': True,
                  'additional_quantization_gate': all(drops[k] <= limits[k] for k in limits)}
    (HERE/'accuracy_review.json').write_text(json.dumps(comparison, indent=2))
    s = json.loads((RUN/'status.json').read_text())
    s.update(stage='complete', status='qat_complete', qat_result=qp, float_tradeoff_accepted_by_user=True)
    (RUN/'status.json').write_text(json.dumps(s, indent=2))
    # User explicitly requested integer validation and hardware evaluation.
    # Keep the accuracy warning, but finish those measurements; this script
    # never promotes a checkpoint or launches physical implementation.
    save(accuracy_warning=not comparison['additional_quantization_gate'])
    deploy = HERE/'integer_export'
    root = Path('/home/lizx/knot_hand_20261002')
    if '--resume-hls' not in sys.argv:
        run('integer_validation', [sys.executable, '-u', PROJECT/'hand_landmark/export_knot_dw3.py',
            '--checkpoint', RUN/'qat/best.pth', '--height', '256', '--width', '320',
            '--src', root/'data/knot/labels1003', '--split', root/'data/knot/split.json',
            '--out', deploy], PROJECT/'hand_landmark', 'KNOT_DW3_EXPORT_PASS')
        run('compile_fixture', [sys.executable, '-u', PROJECT/'pynq_dfx/hls_cnn/compile_nnp.py',
            '--nnp', deploy, '--golden', deploy/'golden', '--out', HERE/'fixtures',
            '--models', 'knot', '--profile', 'knot_dw3', '--tile-in', '4'])
    assert json.loads((deploy/'validation.json').read_text())['integer_accuracy_gate']
    cfg = (HERE/'fixtures/knot/knot_config.hpp').read_text()
    assert '#define CNN_TILE_IN 4' in cfg
    manifest = json.loads((deploy/'manifest.json').read_text())
    assert manifest['input_nchw'] == [1,3,256,320]
    paths = [HERE/'cnn_engine.cpp', HERE/'cnn_engine.hpp', HERE/'check.tcl',
             HERE/'fixtures/knot/knot_config.hpp', HERE/'fixtures/knot/mem_init.bin',
             HERE/'fixtures/knot/golden.bin', RUN/'qat/best.pth']
    (HERE/'input_hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest()
                                                  for p in paths}, indent=2))
    run('hls', ['bash', HERE/'run.sh'], marker=None)
    assert 'KNOT_MAC64_VALIDATION_PASS' in (HERE/'run/console.log').read_text()
    rtl = HERE/'hls_project/solution1/syn/verilog'
    vivado('synthesis', BASE/'synth_ooc.tcl', [rtl, HERE/'resource_review/synthesis'], 'KNOT_OOC_SYNTH_DONE')
    static = Path('/home/lizx/pynq_dfx_jy62_20260930/out/shell_dfx_wide_pr/dfx_routed_shape.dcp')
    vivado('audit', BASE/'audit_u_capacity.tcl', [HERE/'resource_review/synthesis/knot_synth.dcp',
           static, HERE/'resource_review/audit', HERE/'floorplan.tcl'], 'U_CAPACITY_PREFLIGHT_PASS')
    save(stage='ready_for_resource_and_cycle_review', finished=time.time(),
         note='No implementation launched. Review actual cosim cycles and resource reports; 20fps not verified.')
except Exception as exc:
    save(failed_stage=STATE['stage'], stage='failed', reason=str(exc), finished=time.time())
    raise
