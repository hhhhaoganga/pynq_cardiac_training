"""P1 gate: build data/golden/ from the golden model and sanity-check it.

  python golden/selftest.py
Writes data/golden/<buf>.npy and <buf>.bin (raw little-endian, for C/C++ testbenches)
for every buffer, after checking: dtype/shape match the contract, the model is
deterministic, outputs are not trivial, and the model agrees with independent_check().
Prints GATE_PASS.
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skill" / "tools"))
sys.path.insert(0, str(ROOT / "golden"))
import contract as ct  # noqa: E402
import model  # noqa: E402

SEED = 2026


def independent_check(inputs, params, outputs):
    """Second, deliberately different formulation of the same function. Edit per project.
    For real-data tasks also assert a task metric here (accuracy, Dice, PSNR ...),
    because bit-exact against a wrong model is still wrong."""
    a, b = inputs["a"].tolist(), inputs["b"].tolist()
    ref = [((x + y + 2**31) % 2**32) - 2**31 for x, y in zip(a, b)]
    assert outputs["c"].tolist() == ref, "model.run 与独立实现不一致"


def main() -> int:
    c = ct.load(ROOT / "contract.yaml")
    p = c["params"]
    inputs = model.make_inputs(p, np.random.default_rng(SEED))
    out1 = model.run({k: v.copy() for k, v in inputs.items()}, p)
    out2 = model.run({k: v.copy() for k, v in inputs.items()}, p)
    arrays = {**inputs, **out1}
    for b in c["buffers"]:
        a = arrays.get(b["name"])
        assert a is not None, f"模型没有产生缓冲区 {b['name']}"
        assert a.dtype == np.dtype(b["dtype"]), f"{b['name']}: dtype {a.dtype} != 契约 {b['dtype']}"
        assert list(a.shape) == b["shape"], f"{b['name']}: shape {list(a.shape)} != 契约 {b['shape']}"
    for k in out1:
        assert np.array_equal(out1[k], out2[k]), f"{k}: 模型两次运行结果不同（不确定性）"
        assert np.count_nonzero(out1[k]) > 0, f"{k}: 输出全零，测试向量没有区分度"
    # A model.py may carry its own independent_check (see templates/stream); it wins.
    getattr(model, "independent_check", independent_check)(inputs, p, out1)
    d = ROOT / "data" / "golden"
    d.mkdir(parents=True, exist_ok=True)
    for b in c["buffers"]:
        a = arrays[b["name"]]
        np.save(d / f"{b['name']}.npy", a)
        a.astype(a.dtype.newbyteorder("<")).tofile(d / f"{b['name']}.bin")
    print(f"已写入 {d}: {sorted(arrays)} (seed={SEED})")
    print("GATE_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
