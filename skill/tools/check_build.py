"""P3 gate: is the Vivado output usable on the board?

  python skill/tools/check_build.py --dir build/out [--contract contract.yaml]
      [--min-wns 0] [--min-whs 0] [--max-util 90]
Expects in --dir: <stem>.bit, <stem>.hwh (same stem), timing.rpt
(report_timing_summary), utilization.rpt (report_utilization).
With --contract: the IP instance must exist in the hwh and the contract's
register offsets are cross-checked against the hwh register map when present.
Prints GATE_PASS.
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract as ct  # noqa: E402

UTIL_ROWS = ("Slice LUTs", "Slice Registers", "Block RAM Tile", "DSPs")


def parse_timing(text: str) -> dict:
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if "WNS(ns)" in ln and "WHS(ns)" in ln:
            heads = re.split(r"\s{2,}", ln.strip())
            for vals in lines[i + 1:i + 4]:
                cells = vals.split()
                if cells and re.fullmatch(r"-?\d+(\.\d+)?", cells[0]):
                    row = dict(zip(heads, cells))
                    return {"wns": float(row["WNS(ns)"]), "tns": float(row["TNS(ns)"]),
                            "whs": float(row["WHS(ns)"]), "ths": float(row["THS(ns)"]),
                            "met": "All user specified timing constraints are met" in text}
    raise ValueError("timing.rpt 里没找到 Design Timing Summary 的 WNS/WHS 行（需要 report_timing_summary 的输出）")


def parse_util(text: str) -> dict:
    out = {}
    for ln in text.splitlines():
        cells = [x.strip() for x in ln.strip().strip("|").split("|")]
        if len(cells) >= 4 and cells[0] in UTIL_ROWS and cells[0] not in out:
            try:  # columns vary by version; Used is first, Available and Util% are last
                out[cells[0]] = {"used": float(cells[1]), "avail": float(cells[-2]), "util": float(cells[-1])}
            except ValueError:
                continue
    if "Slice LUTs" not in out:
        raise ValueError("utilization.rpt 里没找到 Slice LUTs 行（需要 report_utilization 的输出）")
    return out


def hwh_check(hwh: Path, contract_path: Path) -> tuple:
    c = ct.load(contract_path)
    text = hwh.read_text(encoding="utf-8", errors="replace")
    err, warn = [], []
    m = re.search(rf'<MODULE\b[^>]*\bINSTANCE="{re.escape(c["ip"])}"', text)
    if not m:
        names = sorted(set(re.findall(r'<MODULE\b[^>]*\bINSTANCE="([^"]+)"', text)))
        err.append(f"hwh 中没有实例 {c['ip']}，有: {names}")
        return err, warn
    end = text.find("</MODULE>", m.end())
    block = text[m.end():end if end > 0 else len(text)]
    # Vivado 2024.2 writes decimal offsets (VALUE="16"); older/other tools may write hex (0x10).
    offs = {int(v, 0) for v in re.findall(r'NAME="ADDRESS_OFFSET"\s+VALUE="(0[xX][0-9A-Fa-f]+|\d+)"', block)}
    if offs:
        for r in c["registers"]:
            if r["offset"] not in offs:
                err.append(f"寄存器 {r['name']} 偏移 {r['offset']:#x} 不在 hwh 寄存器表 {sorted(hex(o) for o in offs)} 中")
    else:
        warn.append("hwh 没有该 IP 的寄存器表，跳过偏移交叉检查")
    for s in c.get("streams", []):
        if f'INSTANCE="{s["dma"]}"' not in text:
            err.append(f"hwh 中没有 DMA 实例 {s['dma']}")
    return err, warn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, required=True)
    ap.add_argument("--contract", type=Path)
    ap.add_argument("--min-wns", type=float, default=0.0)
    ap.add_argument("--min-whs", type=float, default=0.0)
    ap.add_argument("--max-util", type=float, default=90.0)
    a = ap.parse_args()
    err, warn = [], []

    bits = sorted(a.dir.glob("*.bit"))
    if len(bits) != 1:
        err.append(f"{a.dir} 下应恰好有 1 个 .bit，找到 {[b.name for b in bits]}")
    else:
        bit, hwh = bits[0], bits[0].with_suffix(".hwh")
        if not hwh.exists():
            err.append(f"缺少 {hwh.name}：PYNQ 按同名 .hwh 解析 ip_dict（从 .gen/.../hw_handoff/ 拷贝并改名）")
        else:
            dt = bit.stat().st_mtime - hwh.stat().st_mtime
            if abs(dt) > 3600:
                warn.append(f".bit 与 .hwh 修改时间相差 {dt / 60:.0f} 分钟，确认来自同一次构建")
            if a.contract:
                e, w = hwh_check(hwh, a.contract)
                err += e
                warn += w
        print(f"bit={bit.name} ({bit.stat().st_size} B)")

    for name, parser in (("timing.rpt", parse_timing), ("utilization.rpt", parse_util)):
        f = a.dir / name
        if not f.exists():
            err.append(f"缺少 {name}")
            continue
        try:
            res = parser(f.read_text(encoding="utf-8", errors="replace"))
        except ValueError as e:
            err.append(str(e))
            continue
        print(f"{name}: {res}")
        if name == "timing.rpt":
            if res["wns"] < a.min_wns:
                err.append(f"WNS={res['wns']} ns < {a.min_wns}：建立时间不满足，降频或在 HLS 里加流水/切分关键路径")
            if res["whs"] < a.min_whs:
                err.append(f"WHS={res['whs']} ns < {a.min_whs}：保持时间违例，通常是约束/跨时钟问题")
        else:
            for row, v in res.items():
                if v["util"] > a.max_util:
                    err.append(f"{row} 利用率 {v['util']}% > {a.max_util}%：布线会拥塞，时序难收敛")
    for w in warn:
        print(f"WARN: {w}")
    for e in err:
        print(f"ERROR: {e}")
    if err:
        return 1
    print("GATE_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
