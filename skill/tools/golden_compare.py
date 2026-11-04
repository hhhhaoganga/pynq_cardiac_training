"""Compare actual outputs with golden outputs using the contract's compare rules.

  python skill/tools/golden_compare.py --contract contract.yaml --expected data/golden --actual board/out
Each output buffer <name> is read from <dir>/<name>.npy, or <dir>/<name>.bin
(raw little-endian, dtype/shape from the contract; what a C/C++ testbench fwrite()s).
Rules: exact | {atol: x} | {rtol: r, atol: x} | {max_mismatch: k}. Prints GATE_PASS.
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract as ct  # noqa: E402


def read(d: Path, b: dict):
    npy, raw = d / f"{b['name']}.npy", d / f"{b['name']}.bin"
    if npy.exists():
        return np.load(npy)
    if raw.exists():
        a = np.fromfile(raw, dtype=np.dtype(b["dtype"]).newbyteorder("<"))
        if a.size != int(np.prod(b["shape"])):
            raise ValueError(f"{raw} 有 {a.size} 个元素，契约要求 {int(np.prod(b['shape']))}")
        return a.reshape(b["shape"])
    raise FileNotFoundError(f"{d} 下找不到 {b['name']}.npy 或 {b['name']}.bin")


def compare(exp, act, rule) -> tuple:
    if exp.shape != act.shape:
        return False, f"shape {list(act.shape)} != 期望 {list(exp.shape)}"
    e, a = exp.astype(np.float64), act.astype(np.float64)
    diff = np.abs(e - a)
    if rule == "exact":
        bad = diff != 0
        ok = not bad.any()
    elif "max_mismatch" in rule:
        bad = diff > rule.get("atol", 0)
        ok = int(bad.sum()) <= rule["max_mismatch"]
    else:
        bad = diff > rule.get("atol", 0) + rule.get("rtol", 0) * np.abs(e)
        ok = not bad.any()
    msg = f"mismatch={int(bad.sum())}/{bad.size} max_abs_err={diff.max():.6g}"
    if bad.any():
        idx = np.argwhere(bad)[:5]
        msg += " 前几个: " + ", ".join(f"{tuple(int(i) for i in ix)} 期望{e[tuple(ix)]:g} 实际{a[tuple(ix)]:g}"
                                    for ix in idx)
        first = int(np.flatnonzero(bad)[0])
        if bad.sum() == bad.size:
            msg += "；全部不同：检查 invalidate()/地址寄存器/数据是否根本没写回"
        elif first > 0 and bad.ravel()[first:].all():
            msg += f"；从第 {first} 个元素起全错：长度寄存器或 DMA 传输长度不对"
        elif np.array_equal(np.sort(e.ravel()), np.sort(a.ravel())):
            msg += "；数值集合相同但位置不同：转置/行列顺序/字节序问题"
    return ok, msg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contract", type=Path, required=True)
    ap.add_argument("--expected", type=Path, required=True)
    ap.add_argument("--actual", type=Path, required=True)
    a = ap.parse_args()
    c = ct.load(a.contract)
    all_ok = True
    for name, rule in c["compare"].items():
        b = ct.buffer(c, name)
        try:
            ok, msg = compare(read(a.expected, b), read(a.actual, b), rule)
        except Exception as e:
            ok, msg = False, str(e)
        all_ok &= ok
        print(f"{'PASS' if ok else 'FAIL'} {name} ({rule}): {msg}")
    if all_ok:
        print("GATE_PASS")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
