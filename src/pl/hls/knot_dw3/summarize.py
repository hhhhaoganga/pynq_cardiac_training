"""Summarize completed measured reports, without launching implementation."""
import json
from pathlib import Path
import re

H = Path(__file__).resolve().parent

def resources(path):
    s = path.read_text()
    result = {}
    for label, key in [('Slice LUTs','LUT'),('Slice Registers','FF'),('Block RAM Tile','BRAM36'),('DSPs','DSP')]:
        for line in s.splitlines():
            cells = [v.strip() for v in line.split('|')]
            if len(cells) > 3 and cells[1].rstrip('*') == label:
                result[key] = float(cells[2])
                break
    return result

state = json.loads((H/'evaluation_status.json').read_text())
assert state['stage'] == 'ready_for_resource_and_cycle_review', state
cosim = (H/'hls_project/solution1/sim/report/cnn_top_cosim.rpt').read_text()
row = next(line for line in cosim.splitlines() if re.search(r'\|\s*Verilog\s*\|',line))
cells = [v.strip() for v in row.split('|')]
assert cells[2].lower() == 'pass', row
cycles = int(cells[5])
ms = cycles/100000.0
syn = resources(H/'resource_review/synthesis/utilization.rpt')
report = {
    'input_hw':[256,320], 'pw_parallel_mac':64, 'clock_target_mhz':100,
    'rtl_cosim_pass':True, 'complete_inference_cycles':cycles, 'simulated_core_ms':ms,
    'remaining_ms_at_20fps':50-ms,
    'fps_if_extra_ms':{str(extra):1000/(ms+extra) for extra in [5,10,15]},
    'actual_ooc_resources':syn,
    'baseline_128mac_320x416_ooc':{'LUT':26707,'FF':24076,'BRAM36':86.5,'DSP':88},
    'buffer_profile':json.loads((H/'fixtures/knot/profile.json').read_text()),
    'integer_validation':json.loads((H/'integer_export/validation.json').read_text()),
    'qat_comparison':json.loads((H/'accuracy_review.json').read_text()),
    'physical_implementation_started':False,
    'limitations':['No placed Slice count or routing/timing closure yet.',
                   'AXI simulation timing is not actual DDR or PS end-to-end latency.',
                   'Accuracy uses the checkpoint-selection validation split, not an independent test.']}
(H/'evaluation_summary.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
