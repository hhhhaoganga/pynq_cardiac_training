"""Agreement of a lagged run against v2 (no ground truth)."""
import numpy as np


def confirmed(r):return [h for h in r['hands'] if h['confirmed']]


def compare(ref,lag):
    """Per frame: confirmed-hand counts, and palm distance (in ROI-side units) to the matched v2 hand."""
    both_ref=both_lag=lost=gained=0;err=[]
    for k,a in ref.items():
        b=lag.get(k);ha=confirmed(a);hb=confirmed(b) if b else []
        both_ref+=len(ha)==2;both_lag+=len(hb)==2
        lost+=max(0,len(ha)-len(hb));gained+=max(0,len(hb)-len(ha))
        for h in ha:
            pa=np.asarray(h['points']);side=h['roi_used'][2]
            if not hb:continue
            d=[np.linalg.norm(np.asarray(g['points'])-pa,axis=1).mean() for g in hb]
            if min(d)<0.5*side:err.append(min(d)/side)
    err=np.asarray(err) if err else np.zeros(1)
    return dict(frames=len(ref),both_confirmed_v2=both_ref,both_confirmed_lag=both_lag,
                hands_missing_vs_v2=lost,hands_extra_vs_v2=gained,
                matched_hands=int(len(err)),mean_point_err_per_roi_side=float(err.mean()),
                p95_point_err_per_roi_side=float(np.percentile(err,95)))
