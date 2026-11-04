"""Golden reference model (AXI-Stream axis_scale example). Copy to <project>/golden/model.py.

  run(inputs, params) -> {"y": x * k + b}  with int32 wraparound, exactly like the HLS kernel.
  independent_check() is picked up by golden/selftest.py when defined here.
"""
import numpy as np


def make_inputs(params, rng):
    n = params["n"]
    # Full int32 range so the multiply really wraps; a narrow range would hide width bugs.
    return {"x": rng.integers(-2**31, 2**31, n, dtype=np.int64).astype(np.int32)}


def run(inputs, params):
    x = inputs["x"]
    k, b = params["k"], params["b"]
    y = (x.astype(np.int64) * k + b) & 0xFFFFFFFF  # wrap in 64-bit, then reinterpret as int32
    return {"y": y.astype(np.uint32).view(np.int32)}


def independent_check(inputs, params, outputs):
    """Pure-Python big-int version of the same function."""
    k, b = params["k"], params["b"]
    ref = [((v * k + b + 2**31) % 2**32) - 2**31 for v in inputs["x"].tolist()]
    assert outputs["y"].tolist() == ref, "model.run 与独立实现不一致"
