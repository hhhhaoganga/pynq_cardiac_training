"""P0 gate and board package generator.

  python skill/tools/gen_driver.py --check contract.yaml
      validate the contract; prints GATE_PASS when there are no errors
  python skill/tools/gen_driver.py --emit contract.yaml [--out board_pkg]
      write board_pkg/: contract.json (resolved) + accel_driver.py, fake_pynq.py,
      board_smoke.py, board_test.py. board.py pushes this directory to the board.
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract as ct  # noqa: E402

SKILL = Path(__file__).resolve().parents[1]
BOARD_FILES = ("accel_driver.py", "fake_pynq.py", "board_smoke.py", "board_test.py")


def check(path: Path) -> int:
    try:
        c = ct.load(path)
    except Exception as e:
        print(f"ERROR: 无法解析 {path}: {e}")
        return 1
    err, warn = ct.validate(c, root=path.parent)
    for w in warn:
        print(f"WARN: {w}")
    for e in err:
        print(f"ERROR: {e}")
    print(f"buffers={[(b['name'], b['dtype'], b['shape']) for b in c.get('buffers', [])]}")
    print(f"registers={[(r['name'], hex(r['offset']), r['width']) for r in c.get('registers', [])]}")
    if err:
        print(f"{len(err)} 个错误，修改 contract.yaml 后重跑")
        return 1
    print("GATE_PASS")
    return 0


def emit(path: Path, out: Path) -> int:
    c = ct.load(path)
    err, _ = ct.validate(c, root=path.parent)
    if err:
        print("契约有错误，先让 --check 通过")
        return 1
    out.mkdir(parents=True, exist_ok=True)
    (out / "contract.json").write_text(json.dumps(c, ensure_ascii=False, indent=1), encoding="utf-8")
    for f in BOARD_FILES:
        shutil.copy2(SKILL / "board" / f, out / f)
    print(f"已生成 {out}/: contract.json, {', '.join(BOARD_FILES)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", type=Path)
    g.add_argument("--emit", type=Path)
    ap.add_argument("--out", type=Path, default=Path("board_pkg"))
    a = ap.parse_args()
    return check(a.check) if a.check else emit(a.emit, a.out)


if __name__ == "__main__":
    sys.exit(main())
