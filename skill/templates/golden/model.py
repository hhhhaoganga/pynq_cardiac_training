"""Golden reference model (vadd example). Copy to <project>/golden/model.py and edit.

Contract with the tools:
  run(inputs: dict[name -> np.ndarray], params: dict) -> dict[output name -> np.ndarray]
  make_inputs(params: dict, rng) -> dict of input arrays (dtype/shape exactly as contract.yaml)
Write it the way the hardware computes (same integer widths, rounding, saturation,
memory order), not the "nicest" float version, or P2/P5 compares will never pass.
"""
import numpy as np


def make_inputs(params, rng):
    n = params["n"]
    return {
        "a": rng.integers(-1000, 1000, n, dtype=np.int32),
        "b": rng.integers(-1000, 1000, n, dtype=np.int32),
    }


def run(inputs, params):
    a, b = inputs["a"], inputs["b"]
    n = params["n"]
    c = np.zeros_like(a)
    c[:n] = (a[:n].astype(np.int64) + b[:n]).astype(np.int32)  # int32 wrap like the HLS int
    return {"c": c}
