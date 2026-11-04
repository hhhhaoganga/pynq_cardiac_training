"""P4 smoke test, run on PYNQ Linux inside the run dir (contract.json, accel_driver.py, *.bit, *.hwh).

Checks in order and stops at the first failure, so the printed step names the problem:
env -> files -> overlay -> ip -> registers -> buffers -> one kernel run with deadline.
Prints GATE_PASS and a JSON summary on success.
"""
import json
import os
import sys
import time
import traceback
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
report = {}


def step(name):
    print(f"[smoke] {name}", flush=True)


def fail(msg):
    print(f"SMOKE_FAIL: {msg}")
    print(json.dumps(report, ensure_ascii=False, indent=1))
    sys.exit(1)


def main():
    fake = bool(os.environ.get("PYNQ_FAKE"))
    step("env")
    if not fake and os.geteuid() != 0:
        fail("需要 root（sudo -E 或 board.py 自动 sudo），否则 Overlay/allocate 会报权限错误")
    try:
        import accel_driver
    except ImportError as e:
        fail(f"import 失败 {e}：确认已 source /etc/profile.d/pynq_venv.sh 和 xrt_setup.sh")
    report["pynq"] = getattr(accel_driver.pynq, "__version__", "?")
    report["board"] = os.environ.get("BOARD", "?")

    step("files")
    c = json.loads((HERE / "contract.json").read_text(encoding="utf-8"))
    bit = HERE / Path(c["overlay"]).name
    for f in (bit, bit.with_suffix(".hwh")):
        if not f.exists():
            fail(f"缺少 {f.name}（.bit 与 .hwh 必须同名同目录）")
    report["bit_bytes"] = bit.stat().st_size

    step("overlay")
    getattr(os, "sync", lambda: None)()  # a hung AXI access freezes the board; keep the filesystem consistent first
    t = time.perf_counter()
    try:
        acc = accel_driver.Accel(HERE / "contract.json")
    except Exception as e:
        traceback.print_exc()
        fail(str(e))
    report["overlay_load_ms"] = round((time.perf_counter() - t) * 1e3, 1)
    report["ips"] = sorted(acc.ol.ip_dict)

    step("registers")
    if c["control"] == "hls":
        ctrl = acc.mmio.read(0x0)
        report["ctrl_before"] = f"{ctrl:#x}"
        if ctrl == 0xFFFFFFFF:
            fail("控制寄存器读到 0xFFFFFFFF：IP 地址错误或 PL 时钟/复位没起来")
        if not ctrl & 0x4:
            fail(f"ap_idle=0（ctrl={ctrl:#x}）：内核没处于空闲，检查 ap_rst_n 与 fclk")
    for r in c["registers"]:
        got = acc.mmio.read(r["offset"])
        want = (int(acc.buf[r["buffer"]].physical_address) if r["kind"] == "addr" else r["value"]) & 0xFFFFFFFF
        if got != want:
            fail(f"寄存器 {r['name']}@{r['offset']:#x} 回读 {got:#x} != 写入 {want:#x}：偏移与 HLS *_hw.h 不一致？")

    step("buffers")
    for name, b in acc.buf.items():
        pa = int(b.physical_address)
        if pa == 0 or pa % 64:
            fail(f"缓冲区 {name} 物理地址 {pa:#x} 异常（应非零且 64 字节对齐）")
    report["buffers"] = {n: f"{int(b.physical_address):#x}" for n, b in acc.buf.items()}

    step("run")
    inputs = {}
    for b in c["buffers"]:
        if b["dir"] != "out":
            f = HERE / "golden" / f"{b['name']}.npy"
            inputs[b["name"]] = np.load(f) if f.exists() else np.zeros(b["shape"], b["dtype"])
    getattr(os, "sync", lambda: None)()
    t = time.perf_counter()
    try:
        outs = acc(inputs)
    except Exception as e:
        traceback.print_exc()
        fail(f"首次运行失败: {e}")
    report["first_run_ms"] = round((time.perf_counter() - t) * 1e3, 3)
    report["outputs_nonzero"] = {n: int(np.count_nonzero(a)) for n, a in outs.items()}
    acc.close()
    print(json.dumps(report, ensure_ascii=False, indent=1))
    print("GATE_PASS")


if __name__ == "__main__":
    main()
