"""P6 gate: performance report from measured data only.

  python skill/tools/perf_report.py --out report/perf.md [--build build/out]
Reads board/out/timing.json (board_test.py) and, if present, the build reports.
Refuses to pass on fake-board data or missing measurements, so the report can
never contain made-up numbers. Prints GATE_PASS.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_build  # noqa: E402
import contract as ct  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--timing", type=Path, default=Path("board/out/timing.json"))
    ap.add_argument("--build", type=Path, default=Path("build/out"))
    ap.add_argument("--allow-fake", action="store_true", help="for testing the tool itself")
    a = ap.parse_args()
    if not a.timing.exists():
        print(f"ERROR: 没有 {a.timing}，先通过 P5（board.py test 会生成它）")
        return 1
    t = json.loads(a.timing.read_text(encoding="utf-8"))
    if t.get("fake") and not a.allow_fake:
        print("ERROR: timing.json 来自 --board fake，性能数据必须在真板上测")
        return 1
    c = ct.load("contract.yaml")
    lines = [f"# {c['name']} 性能报告", "",
             f"板卡: {t.get('board', c.get('board', '?'))}  pynq: {t.get('pynq', '?')}  "
             f"驱动: {t.get('backend', 'python')}  数据: {a.timing}（board_test.py 实测）", "",
             "| 项目 | 平均 ms | 最小 ms | P95 ms | 次数 |", "|---|---|---|---|---|"]
    names = {"end_to_end": "端到端（写入+运行+读出）", "write_inputs": "写入+flush",
             "kernel": "内核运行（含 DMA）", "read_outputs": "invalidate+读出", "cpu_baseline": "ARM CPU 软件基线"}
    for k, label in names.items():
        if k in t:
            v = t[k]
            lines.append(f"| {label} | {v['mean_ms']:.3f} | {v['min_ms']:.3f} | {v['p95_ms']:.3f} | {v['n']} |")
    if "cpu_baseline" in t:
        sp = t["cpu_baseline"]["mean_ms"] / t["end_to_end"]["mean_ms"]
        lines += ["", f"加速比（CPU 基线 / 端到端）: {sp:.2f}x"]
        share = t["kernel"]["mean_ms"] / t["end_to_end"]["mean_ms"]
        lines.append(f"内核占端到端时间 {share:.0%}：" +
                     ("瓶颈在 PL，优化内核（流水/并行/位宽）" if share > 0.6 else
                      ("瓶颈在 PS 侧：驱动还是纯 Python MMIO（每次寄存器访问约 15 us），"
                       "先让 cross_build.py 通过、用 native 驱动再测" if t.get("backend", "python") == "python" else
                       "瓶颈在 PS 侧搬运/缓存维护，先减少拷贝与 flush，再考虑改内核")))
    tr, ur = a.build / "timing.rpt", a.build / "utilization.rpt"
    if tr.exists() and ur.exists():
        tm = check_build.parse_timing(tr.read_text(encoding="utf-8", errors="replace"))
        ut = check_build.parse_util(ur.read_text(encoding="utf-8", errors="replace"))
        lines += ["", f"时序: WNS {tm['wns']} ns, WHS {tm['whs']} ns", "",
                  "| 资源 | 使用 | 可用 | 利用率 |", "|---|---|---|---|"]
        lines += [f"| {k} | {v['used']:g} | {v['avail']:g} | {v['util']}% |" for k, v in ut.items()]
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    print("GATE_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
