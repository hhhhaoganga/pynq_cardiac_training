#!/usr/bin/env python3
"""Phase/gate state machine for a PYNQ accelerator project.

The agent never decides by itself that a phase is done: `gate.py run` executes
the phase's gate command and only advances when it exits 0 AND prints
GATE_PASS. State lives in skill_state.json next to contract.yaml, so a new
conversation (or a model that lost the thread) can resume from `gate.py status`.

  gate.py init [--board xilinx@192.168.2.99]
  gate.py status
  gate.py run                      run the current phase's gate
  gate.py note "decision ..."      record a decision
  gate.py issue "hypothesis ..."   record an open issue
  gate.py resolve N "how"          close issue N
  gate.py back P2 "reason"         go back to an earlier phase
  gate.py set-gate P1 "cmd"        replace a phase's gate command
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    _s.reconfigure(encoding="utf-8", errors="replace")

SKILL = Path(__file__).resolve().parents[1]
PHASES = [
    ("P0", "契约", "phases/p0_contract.md", "python skill/tools/gen_driver.py --check contract.yaml"),
    ("P1", "黄金参考", "phases/p1_golden.md", "python golden/selftest.py"),
    ("P2", "计算核心", "phases/p2_kernel.md",
     "python skill/tools/golden_compare.py --contract contract.yaml --expected data/golden --actual sim/out"),
    ("P3", "Overlay 构建", "phases/p3_overlay.md", "python skill/tools/check_build.py --dir build/out --contract contract.yaml"),
    ("P4", "上板冒烟", "phases/p4_smoke.md", "python skill/tools/board.py smoke"),
    ("P5", "板上比对", "phases/p5_board.md",
     "python skill/tools/board.py test && python skill/tools/golden_compare.py --contract contract.yaml "
     "--expected data/golden --actual board/out"),
    ("P6", "性能报告", "phases/p6_report.md", "python skill/tools/perf_report.py --out report/perf.md"),
]
IDS = [p[0] for p in PHASES]
MAX_FAILS = 2
GATE_TIMEOUT_S = 900


def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M")


def load(path: Path) -> dict:
    if not path.exists():
        sys.exit(f"没有 {path}。先运行: python skill/tools/gate.py init")
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, st: dict) -> None:
    path.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")


def pitfall_hits(text: str) -> list:
    """Pitfall sections whose 关键词 line matches the failing log."""
    hits, low = [], text.lower()
    f = SKILL / "pitfalls.md"
    if not f.exists():
        return []
    doc = f.read_text(encoding="utf-8")
    for sec in re.split(r"\n(?=## )", doc):
        m = re.search(r"^关键词[:：]\s*(.+)$", sec, re.M)
        if not m:
            continue
        words = [w.strip().lower() for w in m.group(1).split(",") if w.strip()]
        if any(w in low for w in words):
            hits.append(sec.splitlines()[0].lstrip("# ").strip())
    return hits


def cmd_init(path: Path, args) -> None:
    if path.exists() and not args.force:
        sys.exit(f"{path} 已存在（--force 覆盖）")
    st = dict(created=now(), board=args.board, phase="P0",
              phases={pid: dict(name=name, card=card, gate=gate, status="todo", fails=0, passed=None)
                      for pid, name, card, gate in PHASES},
              decisions=[], issues=[])
    save(path, st)
    print(f"已创建 {path}，当前阶段 P0。下一步：读 skill/{PHASES[0][2]}")


def cmd_status(st: dict) -> None:
    pid = st["phase"]
    ph = st["phases"][pid]
    done = [p for p in IDS if st["phases"][p]["status"] == "pass"]
    print(f"当前阶段: {pid} {ph['name']}   已通过: {', '.join(done) or '无'}")
    print(f"卡片:     skill/{ph['card']}")
    print(f"关卡命令: {ph['gate']}")
    print(f"连续失败: {ph['fails']} / {MAX_FAILS}")
    if ph["fails"] >= MAX_FAILS:
        print("!! 已连续失败，先查 skill/pitfalls.md 并用 gate.py issue 记录假设，再改代码")
    open_issues = [i for i in st["issues"] if not i.get("resolved")]
    for i in open_issues:
        print(f"未解决 #{i['id']} [{i['phase']}] {i['text']}")
    for d in st["decisions"][-5:]:
        print(f"决定 [{d['phase']}] {d['text']}")
    if st["board"]:
        print(f"板卡:     {st['board']}")


def cmd_run(path: Path, st: dict) -> int:
    pid = st["phase"]
    ph = st["phases"][pid]
    log_dir = path.parent / "skill_logs"
    log_dir.mkdir(exist_ok=True)
    log = log_dir / f"{pid}_{dt.datetime.now():%m%d_%H%M%S}_try{ph['fails'] + 1}.log"
    print(f"[{pid}] {ph['gate']}")
    try:
        env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}  # Windows pipes default to GBK
        r = subprocess.run(ph["gate"], shell=True, cwd=path.parent, capture_output=True, env=env,
                           text=True, encoding="utf-8", errors="replace", timeout=GATE_TIMEOUT_S)
        out, code = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out, code = f"{e.stdout or ''}{e.stderr or ''}\nGATE_TIMEOUT after {GATE_TIMEOUT_S}s", 124
    log.write_text(out, encoding="utf-8")
    passed = code == 0 and "GATE_PASS" in out
    tail = "\n".join(out.strip().splitlines()[-25:])
    print(tail)
    if passed:
        ph.update(status="pass", fails=0, passed=now())
        nxt = IDS.index(pid) + 1
        if nxt < len(IDS):
            st["phase"] = IDS[nxt]
            print(f"\nGATE_PASS {pid} → 进入 {IDS[nxt]}。下一步：读 skill/{st['phases'][IDS[nxt]]['card']}")
        else:
            print(f"\nGATE_PASS {pid}，全部阶段完成")
    else:
        ph["fails"] += 1
        ph["status"] = "fail"
        why = "退出码非 0" if code else "输出里没有 GATE_PASS"
        print(f"\nGATE_FAIL {pid}（{why}，第 {ph['fails']} 次）完整日志: {log}")
        hits = pitfall_hits(out)
        if hits:
            print("踩坑清单里可能相关的条目: " + "；".join(hits))
        if ph["fails"] >= MAX_FAILS:
            print("!! 连续失败 2 次：停止小修小补。按 skill/pitfalls.md 定位根因，"
                  "用 gate.py issue \"假设：...\" 记录，再动代码")
    save(path, st)
    return 0 if passed else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", default="skill_state.json", help="state file (default ./skill_state.json)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init")
    p.add_argument("--board", default="", help="ssh target of the PYNQ board, e.g. xilinx@192.168.2.99")
    p.add_argument("--force", action="store_true")
    sub.add_parser("status")
    sub.add_parser("run")
    for name in ("note", "issue"):
        sub.add_parser(name).add_argument("text")
    p = sub.add_parser("resolve")
    p.add_argument("id", type=int)
    p.add_argument("text")
    p = sub.add_parser("back")
    p.add_argument("phase", choices=IDS)
    p.add_argument("reason")
    p = sub.add_parser("set-gate")
    p.add_argument("phase", choices=IDS)
    p.add_argument("gate")
    args = ap.parse_args()

    path = Path(args.state).resolve()
    if args.cmd == "init":
        cmd_init(path, args)
        return 0
    st = load(path)
    if args.cmd == "status":
        cmd_status(st)
    elif args.cmd == "run":
        return cmd_run(path, st)
    elif args.cmd == "note":
        st["decisions"].append(dict(phase=st["phase"], time=now(), text=args.text))
    elif args.cmd == "issue":
        st["issues"].append(dict(id=len(st["issues"]) + 1, phase=st["phase"], time=now(), text=args.text))
        print(f"已记录问题 #{len(st['issues'])}")
    elif args.cmd == "resolve":
        for i in st["issues"]:
            if i["id"] == args.id:
                i.update(resolved=now(), how=args.text)
    elif args.cmd == "back":
        if IDS.index(args.phase) > IDS.index(st["phase"]):
            sys.exit("back 只能回到更早的阶段")
        for pid in IDS[IDS.index(args.phase):]:
            st["phases"][pid].update(status="todo", fails=0)
        st["decisions"].append(dict(phase=st["phase"], time=now(), text=f"回退到 {args.phase}：{args.reason}"))
        st["phase"] = args.phase
        print(f"已回退到 {args.phase}，读 skill/{st['phases'][args.phase]['card']}")
    elif args.cmd == "set-gate":
        st["phases"][args.phase]["gate"] = args.gate
    save(path, st)
    return 0


if __name__ == "__main__":
    sys.exit(main())
