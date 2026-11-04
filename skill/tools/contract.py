"""Load, resolve and validate the interface contract (contract.yaml or its resolved contract.json).

Shared by gen_driver.py, golden_compare.py, board.py and board_smoke.py. Only needs
numpy; PyYAML is needed for .yaml only (the board gets the resolved .json).
"""
import json
import re
from pathlib import Path

import sys

import numpy as np

# Agents read tool output through pipes, which default to GBK on Chinese Windows.
for _s in (sys.stdout, sys.stderr):
    if not _s.isatty():
        _s.reconfigure(encoding="utf-8", errors="replace")

CONTROL_KINDS = ("hls", "none")
BUFFER_DIRS = ("in", "out", "inout")
HLS_CTRL_END = 0x10  # 0x00 ap_ctrl, 0x04 GIE, 0x08 IER, 0x0C ISR


def _eval(expr, params: dict) -> int:
    """Integer expression over params only, e.g. 'n * 4'."""
    if isinstance(expr, bool):
        raise ValueError(f"not an integer: {expr!r}")
    if isinstance(expr, int):
        return expr
    if isinstance(expr, str) and re.fullmatch(r"[A-Za-z0-9_\s+\-*/()]+", expr):
        value = eval(expr, {"__builtins__": {}}, dict(params))  # charset above allows no attribute access
        if float(value) != int(value):
            raise ValueError(f"{expr!r} is not an integer")
        return int(value)
    raise ValueError(f"cannot evaluate {expr!r}")


def load(path) -> dict:
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".json":
        return json.loads(text)
    import yaml  # pip install pyyaml
    raw = yaml.safe_load(text)
    return resolve(raw)


def resolve(raw: dict) -> dict:
    """Evaluate shapes / scalar values; keep everything JSON-serialisable."""
    c = json.loads(json.dumps(raw))
    params = {k: _eval(v, {}) for k, v in (c.get("params") or {}).items()}
    c["params"] = params
    for b in c.get("buffers") or []:
        b["shape"] = [_eval(s, params) for s in b.get("shape", [])]
        b["nbytes"] = int(np.prod(b["shape"])) * np.dtype(b["dtype"]).itemsize
    for r in c.get("registers") or []:
        off = r.get("offset", -1)
        r["offset"] = int(off, 0) if isinstance(off, str) else int(off)
        if r.get("kind") == "scalar":
            r["value"] = _eval(r["value"], params)
    c.setdefault("streams", [])
    c.setdefault("compare", {})
    c.setdefault("timeout_s", 2.0)
    return c


def buffer(c: dict, name: str) -> dict:
    return next(b for b in c["buffers"] if b["name"] == name)


def validate(c: dict, root=Path(".")) -> tuple:
    """Return (errors, warnings). Errors block the P0 gate."""
    err, warn = [], []
    for key in ("name", "overlay", "ip", "control", "buffers", "registers"):
        if key not in c:
            err.append(f"缺少字段 {key}")
    if err:
        return err, warn
    if not re.fullmatch(r"[a-z][a-z0-9_]*", str(c["name"])):
        err.append("name 只能用小写字母/数字/下划线（它会成为板上目录名）")
    if c["control"] not in CONTROL_KINDS:
        err.append(f"control 必须是 {CONTROL_KINDS} 之一")
    if not str(c["overlay"]).endswith(".bit"):
        err.append("overlay 必须指向 .bit（同名 .hwh 放在旁边）")
    names = set()
    for b in c["buffers"]:
        n = b.get("name")
        if n in names:
            err.append(f"缓冲区重名 {n}")
        names.add(n)
        try:
            np.dtype(b["dtype"])
        except TypeError:
            err.append(f"缓冲区 {n}: 无效 dtype {b.get('dtype')}")
        if b.get("dir") not in BUFFER_DIRS:
            err.append(f"缓冲区 {n}: dir 必须是 {BUFFER_DIRS} 之一")
        if not b.get("shape") or any(s <= 0 for s in b["shape"]):
            err.append(f"缓冲区 {n}: shape 必须是正整数列表")
        elif b["nbytes"] % 4:
            warn.append(f"缓冲区 {n}: {b['nbytes']} 字节不是 4 的倍数，部分 DMA/m_axi 会读写越界或截断")
    spans = []
    for r in c["registers"]:
        n, off, width = r.get("name"), r.get("offset", -1), r.get("width", 32)
        if width not in (32, 64):
            err.append(f"寄存器 {n}: width 只能是 32 或 64")
        if off % 4:
            err.append(f"寄存器 {n}: 偏移 {off:#x} 没有 4 字节对齐")
        if c["control"] == "hls" and off < HLS_CTRL_END:
            err.append(f"寄存器 {n}: 偏移 {off:#x} 落在 HLS 控制区 0x00-0x0F")
        spans.append((off, off + width // 8, n))
        if r.get("kind") == "addr":
            if r.get("buffer") not in names:
                err.append(f"寄存器 {n}: 引用了不存在的缓冲区 {r.get('buffer')}")
        elif r.get("kind") == "scalar":
            v = r.get("value")
            if not isinstance(v, int) or v < 0 or v >= 1 << width:
                err.append(f"寄存器 {n}: 标量值 {v!r} 超出 {width} 位")
        else:
            err.append(f"寄存器 {n}: kind 必须是 addr 或 scalar")
    spans.sort()
    for (a0, a1, an), (b0, _b1, bn) in zip(spans, spans[1:]):
        if b0 < a1:
            err.append(f"寄存器 {an} 与 {bn} 地址重叠（{a0:#x}-{a1 - 1:#x} 与 {b0:#x}）")
    for s in c["streams"]:
        for side, want in (("send", ("in", "inout")), ("recv", ("out", "inout"))):
            if side in s and s[side] not in names:
                err.append(f"流 {s.get('dma')}: {side} 引用了不存在的缓冲区 {s[side]}")
            elif side in s and buffer(c, s[side])["dir"] not in want:
                err.append(f"流 {s.get('dma')}: {side} 缓冲区方向应为 {want}")
    outs = [b["name"] for b in c["buffers"] if b["dir"] in ("out", "inout")]
    if not outs:
        err.append("没有输出缓冲区，无法与黄金参考比对")
    for o in outs:
        if o not in c["compare"]:
            err.append(f"输出 {o} 没有 compare 规则（exact / {{atol: x}} / {{max_mismatch: k}}）")
    for k in c["compare"]:
        if k not in outs:
            err.append(f"compare 里的 {k} 不是输出缓冲区")
    golden = c.get("golden", "")
    if ":" not in golden:
        err.append("golden 应写成 path/to/model.py:function")
    elif not (Path(root) / golden.split(":")[0]).exists():
        warn.append(f"黄金模型 {golden.split(':')[0]} 还不存在（P1 阶段要写）")
    if c["control"] == "none" and not c["streams"]:
        warn.append("control: none 且没有 streams：主机无法启动或等待内核")
    return err, warn
