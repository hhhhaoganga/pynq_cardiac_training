"""Minimal stand-in for the pynq package so the board scripts run on a PC.

Selected by PYNQ_FAKE=1. The "PL" is the golden model: writing ap_start (or arming
a DMA send) runs golden(inputs, params) and fills the output buffers. This checks
the driver logic (register map, buffer plumbing, flush/invalidate calls, timeouts)
before any hardware exists. It cannot catch timing, cache or bus bugs.

PYNQ_FAKE_ROOT  project root used to resolve contract["golden"] (default: cwd)
PYNQ_FAKE_HANG=1  never finish, to exercise the driver's timeout path
"""
import importlib.util
import json
import os
from pathlib import Path

import numpy as np

__version__ = "fake"
_REGS = {}      # phys_addr -> {offset: value}
_BUFS = {}      # phys_addr -> PynqBuffer
_KERNELS = {}   # phys_addr -> _Kernel driven by ap_start at that base
_next_addr = [0x1000_0000]
_IP_BASE = 0x4000_0000


class PynqBuffer(np.ndarray):
    def flush(self):
        self._flushed = True

    def invalidate(self):
        pass

    def freebuffer(self):
        _BUFS.pop(self.physical_address, None)


def allocate(shape, dtype):
    a = np.zeros(shape, dtype=dtype).view(PynqBuffer)
    a.physical_address = _next_addr[0]
    a._flushed = False
    _next_addr[0] += (a.nbytes + 0xFFF) & ~0xFFF
    _BUFS[a.physical_address] = a
    return a


class _Kernel:
    """Runs the golden model against whatever buffers the registers point at."""

    def __init__(self, contract: dict):
        self.c = contract
        root = Path(os.environ.get("PYNQ_FAKE_ROOT", "."))
        path, fn = contract["golden"].split(":")
        spec = importlib.util.spec_from_file_location("golden_model", root / path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.fn = getattr(mod, fn)
        self.stream_bufs = {}

    def execute(self, regs: dict, stream_bufs=None):
        by_name = {**self.stream_bufs, **(stream_bufs or {})}
        for r in self.c["registers"]:
            if r["kind"] == "addr":
                addr = regs.get(r["offset"], 0) | (regs.get(r["offset"] + 4, 0) << 32 if r["width"] == 64 else 0)
                if addr not in _BUFS:
                    raise RuntimeError(f"[fake] 寄存器 {r['name']} 指向未分配地址 {addr:#x}（等同于板上总线错误/死机）")
                by_name[r["buffer"]] = _BUFS[addr]
        params = dict(self.c["params"])
        for r in self.c["registers"]:
            if r["kind"] == "scalar":
                params[r["name"]] = regs.get(r["offset"], 0)
        inputs = {}
        for b in self.c["buffers"]:
            if b["dir"] != "out":
                buf = by_name[b["name"]]
                if not buf._flushed:
                    raise RuntimeError(f"[fake] 输入 {b['name']} 写入后没有 flush()，真板上 PL 会读到旧数据")
                inputs[b["name"]] = np.array(buf)
        outs = self.fn(inputs, params)
        for b in self.c["buffers"]:
            if b["dir"] != "in":
                by_name[b["name"]][:] = outs[b["name"]]


class MMIO:
    def __init__(self, phys_addr, length=0x10000):
        self.base = phys_addr
        self.regs = _REGS.setdefault(phys_addr, {0x0: 0x4})  # ap_idle
        self.kernel = _KERNELS.get(phys_addr)

    def read(self, offset, length=4):
        return self.regs.get(offset, 0)

    def write(self, offset, value):
        self.regs[offset] = int(value) & 0xFFFFFFFF
        if offset == 0x0 and value & 0x1 and self.kernel is not None:
            if os.environ.get("PYNQ_FAKE_HANG"):
                self.regs[0x0] = 0x1  # started, never done/idle
                return
            self.kernel.execute(self.regs)
            self.regs[0x0] = 0x6  # done | idle


class _Channel:
    def __init__(self, dma, sr):
        self.dma, self.sr, self.buf = dma, sr, None

    def transfer(self, buf):
        if self.sr == 0x04:  # like pynq's MM2S channel, flush before the DMA reads
            buf.flush()
        self.buf = buf
        self.dma.mmio.regs[self.sr] = 0x0  # running
        self.dma.kick()


class _Dma:
    def __init__(self, name, kernel, contract):
        self.name, self.kernel, self.c = name, kernel, contract
        self.mmio = MMIO(0x4040_0000 + 0x10000 * len(_REGS))
        self.mmio.regs.update({0x04: 0x1, 0x34: 0x1})
        self.sendchannel, self.recvchannel = _Channel(self, 0x04), _Channel(self, 0x34)

    def kick(self):
        s = next(s for s in self.c["streams"] if s["dma"] == self.name)
        if self.sendchannel.buf is None or ("recv" in s and self.recvchannel.buf is None):
            return
        if os.environ.get("PYNQ_FAKE_HANG"):
            return
        bufs = {s["send"]: self.sendchannel.buf}
        if "recv" in s:
            bufs[s["recv"]] = self.recvchannel.buf
        if self.c["control"] == "none":
            self.kernel.execute({}, bufs)
        else:  # hls + stream: the kernel consumes these when ap_start is written
            self.kernel.stream_bufs.update(bufs)
        self.mmio.regs.update({0x04: 0x2, 0x34: 0x2})  # idle
        self.sendchannel.buf = self.recvchannel.buf = None


class Overlay:
    def __init__(self, bitfile, download=True):
        bit = Path(bitfile)
        if not bit.exists() or not bit.with_suffix(".hwh").exists():
            raise FileNotFoundError(f"[fake] 需要 {bit} 和同名 .hwh（可以是空文件）")
        contract = json.loads((bit.parent / "contract.json").read_text(encoding="utf-8"))
        kernel = _Kernel(contract)
        self.ip_dict = {contract["ip"]: {"phys_addr": _IP_BASE, "addr_range": 0x10000}}
        _REGS.pop(_IP_BASE, None)
        _KERNELS[_IP_BASE] = kernel if contract["control"] == "hls" else None
        for s in contract["streams"]:
            self.ip_dict[s["dma"]] = {"phys_addr": 0, "addr_range": 0x10000}
            setattr(self, s["dma"], _Dma(s["dma"], kernel, contract))
