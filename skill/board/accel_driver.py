"""Generic PYNQ accelerator driver, driven entirely by contract.json.

Runs on PYNQ Linux (as root, PYNQ venv sourced). Set PYNQ_FAKE=1 to run on a PC
against fake_pynq.py, which executes the golden model instead of the PL.

Every wait has a deadline: a kernel that never asserts ap_done or a DMA that never
goes idle raises TimeoutError with register dumps instead of hanging the board.
"""
import json
import os
import time
from pathlib import Path

import numpy as np

if os.environ.get("PYNQ_FAKE"):
    import fake_pynq as pynq
else:
    import pynq

AP_START, AP_DONE, AP_IDLE = 0x1, 0x2, 0x4
DMA_MM2S_SR, DMA_S2MM_SR = 0x04, 0x34
DMASR_HALTED, DMASR_IDLE = 0x1, 0x2
DMASR_ERR = 0x70  # DMAIntErr | DMASlvErr | DMADecErr
NATIVE_ERRORS = {-1: "打不开 /dev/mem（需要 root）", -2: "mmap 失败", -3: "启动前内核不空闲",
                 -4: "ap_done 超时", -5: "DMA 超时", -6: "DMA 报错"}


def _load_native():
    """accel_native.so (cross-built by tools/cross_build.py) or None -> pure-Python path."""
    if os.environ.get("PYNQ_FAKE") or os.environ.get("PYNQ_NATIVE") == "0":
        return None
    so = Path(__file__).resolve().parent / "accel_native.so"
    if not so.exists():
        return None
    import ctypes as C
    try:
        lib = C.CDLL(str(so))
    except OSError as e:  # wrong arch / glibc too new: say so, keep working in Python
        print(f"[accel_driver] accel_native.so 加载失败，退回 Python MMIO: {e}")
        return None
    u32p = C.POINTER(C.c_uint32)
    lib.accel_run.argtypes = [C.c_uint32, C.c_int, C.c_int, u32p, u32p, u32p, u32p, u32p,
                              C.c_double, u32p]
    lib.accel_run.restype = C.c_int
    return lib


def _decode_dmasr(v: int) -> str:
    bits = [("halted", 0x1), ("idle", 0x2), ("int_err", 0x10), ("slv_err", 0x20),
            ("dec_err", 0x40), ("ioc", 0x1000), ("err_irq", 0x4000)]
    return f"{v:#010x} (" + ",".join(n for n, m in bits if v & m) + ")"


class Accel:
    def __init__(self, contract_path="contract.json", download=True):
        self.c = json.loads(Path(contract_path).read_text(encoding="utf-8"))
        self.timeout_s = float(self.c["timeout_s"])
        bit = str(Path(contract_path).parent / Path(self.c["overlay"]).name)
        try:
            self.ol = pynq.Overlay(bit, download=download)
        except Exception as e:  # hwh parse failures still leave a usable bitstream path
            raise RuntimeError(f"Overlay({bit}) 失败: {e}；检查 .bit/.hwh 是否同名且来自同一次构建") from e
        ips = self.ol.ip_dict
        if self.c["ip"] not in ips:
            raise KeyError(f"ip {self.c['ip']!r} 不在 hwh 中，可选: {sorted(ips)}")
        desc = ips[self.c["ip"]]
        self.mmio = pynq.MMIO(desc["phys_addr"], desc["addr_range"])
        self.dmas = {s["dma"]: getattr(self.ol, s["dma"]) for s in self.c["streams"]}
        self._send_bufs = {s["send"] for s in self.c["streams"] if "send" in s}
        self.buf = {b["name"]: pynq.allocate(shape=tuple(b["shape"]), dtype=b["dtype"])
                    for b in self.c["buffers"]}
        self._program_registers()
        self.native = _load_native()
        self.backend = "native" if self.native else "python"
        if self.native:
            self._prepare_native(ips, desc)

    def _prepare_native(self, ips, desc):
        """Buffers never move after allocate(), so the ctypes argument arrays are built once."""
        import ctypes as C
        names = list(self.dmas)
        n = len(names)
        arr = lambda vals: (C.c_uint32 * max(n, 1))(*vals)
        size = lambda name: int(self.buf[name].nbytes)
        addr = lambda name: int(self.buf[name].physical_address)
        by = {s["dma"]: s for s in self.c["streams"]}
        self._nargs = (
            int(desc["phys_addr"]), int(self.c["control"] == "hls"), n,
            arr([int(ips[d]["phys_addr"]) for d in names]),
            arr([addr(by[d]["send"]) if "send" in by[d] else 0 for d in names]),
            arr([size(by[d]["send"]) if "send" in by[d] else 0 for d in names]),
            arr([addr(by[d]["recv"]) if "recv" in by[d] else 0 for d in names]),
            arr([size(by[d]["recv"]) if "recv" in by[d] else 0 for d in names]),
            C.c_double(self.timeout_s),
        )
        self._nstatus = (C.c_uint32 * (1 + 2 * max(n, 1)))()

    # -- registers -------------------------------------------------------
    def _program_registers(self):
        for r in self.c["registers"]:
            if r["kind"] == "addr":
                v = int(self.buf[r["buffer"]].physical_address)
            else:
                v = int(r["value"])
            self.mmio.write(r["offset"], v & 0xFFFFFFFF)
            if r["width"] == 64:
                self.mmio.write(r["offset"] + 4, (v >> 32) & 0xFFFFFFFF)

    def set_scalar(self, name: str, value: int):
        r = next(r for r in self.c["registers"] if r["name"] == name and r["kind"] == "scalar")
        r["value"] = int(value)
        self.mmio.write(r["offset"], value & 0xFFFFFFFF)
        if r["width"] == 64:
            self.mmio.write(r["offset"] + 4, (value >> 32) & 0xFFFFFFFF)

    def dump(self) -> dict:
        regs = {"ctrl": f"{self.mmio.read(0x0):#x}"} if self.c["control"] == "hls" else {}
        for r in self.c["registers"]:
            regs[r["name"]] = f"{self.mmio.read(r['offset']):#x}"
        for name, dma in self.dmas.items():
            regs[f"{name}.mm2s_sr"] = _decode_dmasr(dma.mmio.read(DMA_MM2S_SR))
            regs[f"{name}.s2mm_sr"] = _decode_dmasr(dma.mmio.read(DMA_S2MM_SR))
        return regs

    # -- data ------------------------------------------------------------
    def write_inputs(self, arrays: dict):
        for b in self.c["buffers"]:
            if b["dir"] == "out":
                continue
            a = np.asarray(arrays[b["name"]])
            if a.shape != tuple(b["shape"]) or a.dtype != np.dtype(b["dtype"]):
                raise ValueError(f"{b['name']}: 期望 {b['dtype']}{b['shape']}，得到 {a.dtype}{list(a.shape)}")
            self.buf[b["name"]][:] = a
            # CPU cache -> DDR before PL reads; pynq's sendchannel.transfer() already
            # flushes stream send buffers on the Python path, so don't pay for it twice
            if self.native or b["name"] not in self._send_bufs:
                self.buf[b["name"]].flush()

    def read_outputs(self) -> dict:
        out = {}
        for b in self.c["buffers"]:
            if b["dir"] != "in":
                self.buf[b["name"]].invalidate()  # drop stale cache lines after PL writes
                out[b["name"]] = np.array(self.buf[b["name"]])
        return out

    # -- execution -------------------------------------------------------
    def _deadline_wait(self, ready, what: str, deadline: float):
        while not ready():
            if time.perf_counter() > deadline:
                raise TimeoutError(f"{what} 超时 {self.timeout_s}s，寄存器: {self.dump()}")

    def _run_native(self):
        rc = self.native.accel_run(*self._nargs, self._nstatus)
        if rc:
            st = list(self._nstatus)
            regs = {"ctrl": f"{st[0]:#x}"}
            for i, name in enumerate(self.dmas):
                regs[f"{name}.mm2s_sr"] = _decode_dmasr(st[1 + 2 * i])
                regs[f"{name}.s2mm_sr"] = _decode_dmasr(st[2 + 2 * i])
            err = TimeoutError if rc in (-4, -5) else RuntimeError
            raise err(f"[native] {NATIVE_ERRORS.get(rc, rc)}，寄存器: {regs}"
                      "（PYNQ_NATIVE=0 可切回 Python 路径对照）")

    def run(self):
        if self.native:
            return self._run_native()
        deadline = time.perf_counter() + self.timeout_s
        for s in self.c["streams"]:  # arm receivers before senders so no beat is lost
            if "recv" in s:
                self.dmas[s["dma"]].recvchannel.transfer(self.buf[s["recv"]])
        for s in self.c["streams"]:
            if "send" in s:
                self.dmas[s["dma"]].sendchannel.transfer(self.buf[s["send"]])
        if self.c["control"] == "hls":
            if not self.mmio.read(0x0) & AP_IDLE:
                raise RuntimeError(f"启动前内核不空闲（上一次未完成或时钟/复位异常），寄存器: {self.dump()}")
            self.mmio.write(0x0, AP_START)
            # ap_done is clear-on-read in older HLS; ap_idle stays set once finished.
            self._deadline_wait(lambda: self.mmio.read(0x0) & (AP_DONE | AP_IDLE), "ap_done", deadline)
        for s in self.c["streams"]:
            dma = self.dmas[s["dma"]]
            for side, sr in (("send", DMA_MM2S_SR), ("recv", DMA_S2MM_SR)):
                if side not in s:
                    continue
                self._deadline_wait(lambda: dma.mmio.read(sr) & (DMASR_IDLE | DMASR_ERR),
                                    f"{s['dma']}.{side}", deadline)
                if dma.mmio.read(sr) & DMASR_ERR:
                    raise RuntimeError(f"{s['dma']}.{side} 报错: {_decode_dmasr(dma.mmio.read(sr))}")

    def __call__(self, arrays: dict) -> dict:
        self.write_inputs(arrays)
        self.run()
        return self.read_outputs()

    def close(self):
        for b in self.buf.values():
            b.freebuffer()
