"""P5/P6 board run: golden inputs -> accelerator -> out/*.npy + out/timing.json.

Run on PYNQ Linux inside the run dir. The comparison itself happens on the PC
(golden_compare.py) so the board needs nothing beyond numpy + pynq.
  python3 board_test.py [--iters 20] [--warmup 2]
If golden/model.py was pushed, also times the same function on the ARM CPU as
the software baseline for the P6 report.
"""
import argparse
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import accel_driver  # noqa: E402


def timed(fn, n):
    ts = []
    for _ in range(n):
        t = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t) * 1e3)
    return {"mean_ms": float(np.mean(ts)), "min_ms": float(np.min(ts)),
            "p95_ms": float(np.percentile(ts, 95)), "n": n}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=2)
    args = ap.parse_args()

    c = json.loads((HERE / "contract.json").read_text(encoding="utf-8"))
    inputs = {b["name"]: np.load(HERE / "golden" / f"{b['name']}.npy")
              for b in c["buffers"] if b["dir"] != "out"}
    getattr(os, "sync", lambda: None)()
    acc = accel_driver.Accel(HERE / "contract.json")
    outs = acc(inputs)  # first run = the result that gets compared
    out_dir = HERE / "out"
    out_dir.mkdir(exist_ok=True)
    for name, a in outs.items():
        np.save(out_dir / f"{name}.npy", a)

    for _ in range(args.warmup):
        acc(inputs)
    timing = {
        "end_to_end": timed(lambda: acc(inputs), args.iters),
        "write_inputs": timed(lambda: acc.write_inputs(inputs), args.iters),
        "kernel": timed(acc.run, args.iters),
        "read_outputs": timed(acc.read_outputs, args.iters),
    }
    model = HERE / "golden" / "model.py"
    if model.exists():
        spec = importlib.util.spec_from_file_location("golden_model", model)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        fn = getattr(mod, c["golden"].split(":")[1])
        timing["cpu_baseline"] = timed(lambda: fn(inputs, c["params"]), max(3, args.iters // 4))
    acc.close()
    timing.update(fake=bool(os.environ.get("PYNQ_FAKE")), board=os.environ.get("BOARD", "?"),
                  backend=acc.backend,
                  pynq=getattr(accel_driver.pynq, "__version__", "?"))
    (out_dir / "timing.json").write_text(json.dumps(timing, indent=1), encoding="utf-8")
    print(json.dumps({k: round(v["mean_ms"], 3) for k, v in timing.items() if isinstance(v, dict)}, indent=1))
    print("BOARD_TEST_DONE")


if __name__ == "__main__":
    main()
