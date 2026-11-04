"""PC-side bridge to a PYNQ Linux board. Every remote call has a timeout.

  python skill/tools/board.py doctor            ssh / sudo / pynq / disk check
  python skill/tools/board.py push              gen_driver --emit + bit/hwh + golden inputs -> board
  python skill/tools/board.py smoke             push, run board_smoke.py      (P4 gate)
  python skill/tools/board.py test              push, run board_test.py, pull board/out/ (P5)
  python skill/tools/board.py run "cmd"         run a command in the board run dir as root
Board target: --board, else $PYNQ_BOARD, else "board" in skill_state.json, e.g. xilinx@192.168.2.99.
--board fake runs everything locally against fake_pynq (no hardware, driver logic only).
SSH key: default ~/.ssh keys, or set PYNQ_SSH_KEY to a private key path.
Sudo: passwordless sudo, or set PYNQ_SUDO_PASS (sent on stdin, never on the command line).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract as ct  # noqa: E402
import gen_driver  # noqa: E402

SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
if os.environ.get("PYNQ_SSH_KEY"):  # non-default private key, e.g. ~/.ssh/pynq_board_ed25519
    SSH_OPTS += ["-i", os.path.expanduser(os.environ["PYNQ_SSH_KEY"])]
PYNQ_ENV = ("for f in /etc/profile.d/xrt_setup.sh /etc/profile.d/boardname.sh "
            "/etc/profile.d/pynq_venv.sh; do [ -f $f ] && . $f; done")
PKG = Path("board_pkg")
FAKE_RUN = Path("board_run_fake")


def target(args) -> str:
    if args.board:
        return args.board
    if os.environ.get("PYNQ_BOARD"):
        return os.environ["PYNQ_BOARD"]
    st = Path("skill_state.json")
    if st.exists() and json.loads(st.read_text(encoding="utf-8")).get("board"):
        return json.loads(st.read_text(encoding="utf-8"))["board"]
    sys.exit("没有板卡地址：gate.py init --board xilinx@<ip>，或 --board / $PYNQ_BOARD；无板调试用 --board fake")


def sh(cmd, timeout, stdin=None) -> tuple:
    """Run a local command; returns (code, output). Never waits on interactive input."""
    try:
        r = subprocess.run(cmd, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out + (f"\nBOARD_TIMEOUT {timeout}s：板卡可能卡死在 AXI 访问上。"
                           "ping 不通就断电重启；能 ping 通就 dmesg 看报错")
    except FileNotFoundError as e:
        return 127, f"{e}：PC 上需要 OpenSSH 客户端（ssh/scp 在 PATH 中）"


def remote(tgt, cmd: str, timeout: int, root=False, in_run=True) -> tuple:
    """Run cmd on the board (in ~/skill_run/<name> if in_run), optionally as root with the PYNQ env.
    The local timeout is the hard limit; cmd should carry its own `timeout` for long work."""
    body = f"{PYNQ_ENV}; {cmd}"
    pw = os.environ.get("PYNQ_SUDO_PASS")
    if root:
        sudo = "sudo -S -p ''" if pw else "sudo -n"
        body = f"{sudo} bash -c {sh_quote(body)}"
    full = f"mkdir -p {RUN_DIR} && cd {RUN_DIR} && {body}" if in_run else f"cd ~ && {body}"
    code, out = sh(["ssh", *SSH_OPTS, tgt, full], timeout + 30, stdin=(pw + "\n") if root and pw else None)
    if "a password is required" in out or "a terminal is required" in out:
        out += "\nsudo 需要密码：设置环境变量 PYNQ_SUDO_PASS，或在板上配置免密 sudo"
    if code == 255:
        out += "\nssh 连接失败：检查 IP/网线/ssh-copy-id 公钥（BatchMode 不会询问密码）"
    return code, out


def sh_quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"


def build_pkg(c: dict) -> None:
    if PKG.exists():
        shutil.rmtree(PKG)
    if gen_driver.emit(Path("contract.yaml"), PKG):
        sys.exit(1)
    bit = Path(c["overlay"])
    for f in (bit, bit.with_suffix(".hwh")):
        if f.exists():
            shutil.copy2(f, PKG / f.name)
    gold = PKG / "golden"
    gold.mkdir()
    for b in c["buffers"]:
        src = Path("data/golden") / f"{b['name']}.npy"
        if b["dir"] != "out" and src.exists():
            shutil.copy2(src, gold / src.name)
    model = Path(c["golden"].split(":")[0])
    if model.exists():
        shutil.copy2(model, gold / "model.py")
    # native fast path: cross-compiled here on the PC; fake mode and missing toolchains fall back to Python
    r = subprocess.run([sys.executable, str(Path(__file__).with_name("cross_build.py")), "--out", str(PKG)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    last = (r.stdout + r.stderr).strip().splitlines()
    print("[cross_build] " + (last[-1] if last else f"exit {r.returncode}") +
          ("" if r.returncode == 0 else "（驱动将用纯 Python MMIO）"))
    if r.returncode == 1:
        print(r.stdout + r.stderr)


def push(tgt, c) -> int:
    build_pkg(c)
    if tgt == "fake":
        if FAKE_RUN.exists():
            shutil.rmtree(FAKE_RUN)
        shutil.copytree(PKG, FAKE_RUN)
        bit = FAKE_RUN / Path(c["overlay"]).name
        for f in (bit, bit.with_suffix(".hwh")):
            if not f.exists():
                f.write_bytes(b"")  # fake_pynq only needs the files to exist
        print(f"[fake] 已复制到 {FAKE_RUN}/")
        return 0
    # out/ was written by root last time, so delete as root but recreate as the ssh user (scp needs write access)
    code, out = remote(tgt, f"rm -rf {RUN_DIR}", 20, root=True, in_run=False)
    if not code:
        code, out = remote(tgt, "mkdir -p skill_run", 20, in_run=False)
    if code:
        print(out)
        return code
    # relative paths only: a Windows drive letter "D:\..." would be parsed by scp as host "D"
    code, out = sh(["scp", "-q", "-r", *SSH_OPTS, str(PKG), f"{tgt}:{RUN_DIR}"], 120)
    print(out.strip() or f"已推送 {PKG}/ -> {tgt}:{RUN_DIR}")
    return code


def run_board(tgt, script: str, timeout: int) -> tuple:
    if tgt == "fake":
        env = {**os.environ, "PYNQ_FAKE": "1", "PYNQ_FAKE_ROOT": str(Path.cwd()), "PYTHONUTF8": "1"}
        try:
            r = subprocess.run([sys.executable, "-u", *script.split()], cwd=FAKE_RUN, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=timeout)
            return r.returncode, r.stdout + r.stderr
        except subprocess.TimeoutExpired:
            return 124, f"BOARD_TIMEOUT {timeout}s"
    return remote(tgt, f"timeout {timeout} python3 -u {script} 2>&1", timeout, root=True)


def pull_out(tgt) -> int:
    dst = Path("board/out")
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(exist_ok=True)
    if tgt == "fake":
        shutil.copytree(FAKE_RUN / "out", dst)
        return 0
    code, out = sh(["scp", "-q", "-r", *SSH_OPTS, f"{tgt}:{RUN_DIR}/out", "board"], 120)
    if code:
        print(out)
    return code


def doctor(tgt) -> int:
    if tgt == "fake":
        print("fake 模式：无需板卡")
        return 0
    checks = [
        ("ssh", "echo ok", False),
        ("sudo+pynq", "python3 -c 'import pynq,numpy;print(\"pynq\",pynq.__version__,\"numpy\",numpy.__version__)'", True),
        ("board", "echo BOARD=$BOARD; uname -m", True),
        ("glibc", "ldd --version | head -1  # cross_build.py --max-glibc must be <= this", False),
        ("disk/mem", "df -h ~ | tail -1; free -m | head -2", False),
        ("fpga", "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo n/a", False),
    ]
    bad = 0
    for name, cmd, root in checks:
        code, out = remote(tgt, cmd, 20, root=root)
        print(f"[{'ok' if code == 0 else 'FAIL'}] {name}: {out.strip()}")
        bad += code != 0
        if name == "ssh" and code:
            return 1
    return 1 if bad else 0


def main() -> int:
    global RUN_DIR
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["doctor", "push", "smoke", "test", "run"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--board")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--iters", type=int, default=20)
    a = ap.parse_args()
    tgt = target(a)
    c = ct.load("contract.yaml")
    RUN_DIR = f"skill_run/{c['name']}"
    if a.cmd == "doctor":
        return doctor(tgt)
    if a.cmd == "run":
        code, out = (run_board(tgt, a.arg, a.timeout) if tgt == "fake"
                     else remote(tgt, f"timeout {a.timeout} {a.arg} 2>&1", a.timeout, root=True))
        print(out)
        return code
    if push(tgt, c):
        return 1
    if a.cmd == "push":
        return 0
    script = "board_smoke.py" if a.cmd == "smoke" else f"board_test.py --iters {a.iters}"
    code, out = run_board(tgt, script, a.timeout)
    print(out.rstrip())
    if a.cmd == "test":
        if code or "BOARD_TEST_DONE" not in out:
            return code or 1
        code = pull_out(tgt)
        print(f"输出已拉回 board/out/" if code == 0 else "拉回 board/out 失败")
    return code


RUN_DIR = "skill_run/default"

if __name__ == "__main__":
    sys.exit(main())
