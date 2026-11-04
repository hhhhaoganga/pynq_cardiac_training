"""Report fresh-result intervals from current service invocations, never video FPS."""
import json,re,subprocess
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parent
def journal(unit):
    invocation=subprocess.check_output(['systemctl','show',unit,'--property=InvocationID','--value'],text=True).strip()
    assert invocation
    data=subprocess.check_output(['journalctl',f'_SYSTEMD_INVOCATION_ID={invocation}','-o','cat','--no-pager'],text=True)
    (ROOT/(unit+'_live.log')).write_text(data)
    return invocation,data
def stats(values):
    if not values:return None
    a=np.asarray(values,float)
    return dict(count=len(a),mean=float(a.mean()),median=float(np.median(a)),p95=float(np.percentile(a,95)),maximum=float(a.max()))
def main():
    ui_id,ui=journal('echo-demo');backend_id,backend=journal('hand-sv')
    rows=[]
    for line in ui.splitlines():
        if line.startswith('HAND_FRESH_RESULT '):
            rows.append({k:float(v) for k,v in re.findall(r'(\w+)=([0-9.]+)',line)})
    logs=[]
    for line in backend.splitlines():
        if line.startswith('{'):
            try:r=json.loads(line)
            except ValueError:continue
            if 'shared_dma' in r:logs.append(r)
    both=[r for r in rows if r['hands']==2]
    consecutive=[r for previous,r in zip(rows,rows[1:]) if previous['hands']==2 and r['hands']==2 and r['seq']>previous['seq'] and r['interval_ms']>0]
    report=dict(ui_invocation=ui_id,backend_invocation=backend_id,results=len(rows),both_hands_results=len(both),recovery_results=sum(r['recovery']!=0 for r in rows),
        all_result_interval_ms=stats([r['interval_ms'] for r in rows if r['interval_ms']>0]),
        both_hands_consecutive_interval_ms=stats([r['interval_ms'] for r in consecutive]),
        both_hands_total_ms=stats([r['total_ms'] for r in both]),
        both_hands_frame_age_ms=stats([r['age_ms'] for r in both]),
        driver_timestamps_all=bool(rows) and all(r['driver_stamp'] for r in rows),
        both_hands_consecutive_fps=1000/np.mean([r['interval_ms'] for r in consecutive]) if consecutive else None,
        sampled_service_rows=logs,live_14fps_accepted=False)
    (ROOT/'live_performance.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='sampled_service_rows'}))
if __name__=='__main__':main()
