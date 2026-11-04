#!/usr/bin/env python3
"""Scripted mouse test of echo_demo (run on the board as root, service running).

Drives /tmp/echo_demo_input: pins the demo to segmentation, runs a complete
biplane EF measurement (apex / base clicks on ED and ES of both views),
recomputes EDV/ESV/EF in Python from the same masks and the clicked points,
then drags the 3D view. Screenshots go to /tmp/ui_*.png.

Usage: sudo python3 ui_mouse_check.py
"""
import math
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_check as pc  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FIFO, SHOT = "/tmp/echo_demo_input", "/tmp/echo_demo_shot"
VIEW_X, VIEW_Y, VIEW_S, DISKS = (18, 442), 102, 400, 20


def mouse(*lines, gap=0.12):
    for line in lines:
        with open(FIFO, "w") as f:
            f.write(line + "\n")
        time.sleep(gap)


def shot(name):
    with open(SHOT, "w") as f:
        f.write(f"/tmp/ui_{name}.png\n")
    time.sleep(0.6)


def measure_profile(mask, sx, sy, apex, base):
    """Port of biplane.hpp measure_profile; returns (rc, length, diameters)."""
    h, w = mask.shape
    dx, dy = (base[0] - apex[0]) * sx, (base[1] - apex[1]) * sy
    length = math.hypot(dx, dy)
    if length <= 2 * max(sx, sy):
        return -2, 0, None
    step, limit = min(sx, sy) / 4, math.hypot(w * sx, h * sy)
    diam = []
    for d in range(DISKS):
        t = (d + 0.5) / DISKS
        cx, cy = apex[0] * sx + t * dx, apex[1] * sy + t * dy
        ix, iy = math.floor(cx / sx + 0.5), math.floor(cy / sy + 0.5)
        if not (0 <= ix < w and 0 <= iy < h) or mask[iy, ix] != 1:
            return -3, 0, None
        ext = []
        for sign in (-1, 1):
            r, hit = step, None
            while r <= limit:
                x = math.floor((cx - sign * r * dy / length) / sx + 0.5)
                y = math.floor((cy + sign * r * dx / length) / sy + 0.5)
                if not (0 <= x < w and 0 <= y < h):
                    return -4, 0, None
                if mask[y, x] != 1:
                    hit = r - step / 2
                    break
                r += step
            if hit is None:
                return -4, 0, None
            ext.append(hit)
        diam.append(ext[0] + ext[1])
    return 0, length, diam


def volume(a, b, length):
    return math.pi * sum(x * y for x, y in zip(a[2], b[2])) * length / (4 * DISKS * 1000)


def landmarks(mask):
    """Test landmarks: apex a few pixels below the LV top, base mid-row near the LV bottom."""
    ys, xs = np.nonzero(mask == 1)
    top, bot = ys.min(), ys.max()
    ya = top + 4
    yb = bot - max(3, (bot - top) // 12)
    ax, bx = xs[ys == ya], xs[ys == yb]
    return (float(ax.min() + ax.max()) / 2, float(ya)), (float(bx.min() + bx.max()) / 2, float(yb))


def to_screen(vi, p):
    """Mask point -> click pixel, and the mask point the UI derives from that pixel."""
    sx = round((p[0] + 0.5) * VIEW_S / 256 - 0.5) + VIEW_X[vi]
    sy = round((p[1] + 0.5) * VIEW_S / 256 - 0.5) + VIEW_Y
    eff = ((sx - VIEW_X[vi] + 0.5) * 256 / VIEW_S - 0.5, (sy - VIEW_Y + 0.5) * 256 / VIEW_S - 0.5)
    return sx, sy, eff


def main():
    seqs = []
    for line in (ROOT / "data/demo/seqs.txt").read_text().split("\n"):
        p = line.split()
        if len(p) == 5:
            seqs.append((p[0], int(p[1]), int(p[2]), int(p[3]), int(p[4])))
    sx, sy = seqs[0][3] * 1e-6, seqs[0][4] * 1e-6

    # 1. Masks of every demo frame (same PL, same history reset as the demo loop).
    sock = socket.create_connection(("127.0.0.1", 5001), timeout=30)
    views, fid = [], 70000
    for file, view, study, spx, spy in seqs:
        frames = np.load(ROOT / "data/demo" / file)
        masks, _, _ = pc.seg_run(sock, frames, None, fid, window=4, meta=(study, spx, spy, 10001), view=view)
        fid += 1000
        views.append(np.stack(masks))
    sock.close()
    # ED = largest LV area so far, ES = smallest (strict, first wins), as in worker.cpp.
    keys = []
    for m in views:
        area = [(k == 1).sum() for k in m]
        ed = int(np.argmax(area))
        es = int(np.argmin(area))
        keys.append((ed, es))
    print("python keyframes (ED, ES):", keys)

    # 2. Drive the UI.
    cursor = subprocess.run(["journalctl", "-u", "echo-demo", "--show-cursor", "-n", "0", "-q"],
                            capture_output=True, text=True).stdout.strip().split()[-1]
    time.sleep(1.0)
    mouse("move 640 360", "click 350 28")          # tab: segmentation (4 tabs) (pins the demo loop)
    time.sleep(7.5)                                # both views once through
    shot("seg")
    mouse("click 1195 323")                        # 双平面 EF 测量
    time.sleep(0.5)
    shot("measure_start")
    for ph in (0, 1):
        for vi in (0, 1):
            apex, base = landmarks(views[vi][keys[vi][ph]])
            ax, ay, _ = to_screen(vi, apex)
            bx, by, _ = to_screen(vi, base)
            mouse(f"click {ax} {ay}", f"click {bx} {by}", gap=0.2)
        time.sleep(0.4)
    time.sleep(0.5)
    shot("measure_done")

    # 3. Check the UI result against Python on the frames and points the UI used.
    log = subprocess.run(["journalctl", "-u", "echo-demo", "--after-cursor", cursor, "-o", "cat", "--no-pager"],
                         capture_output=True, text=True).stdout
    line = [ln for ln in log.splitlines() if ln.startswith("ui: biplane")]
    ok = bool(line)
    if line:
        ln = line[-1]
        print(ln)
        ui = dict(zip(("edv", "esv", "ef"), map(float, re.search(
            r"EDV ([\d.]+) ml ESV ([\d.]+) ml EF ([\d.]+)%", ln).groups())))
        prof = {}
        for v, ph, f, ax, ay, bx, by in re.findall(
                r"v(\d)(ED|ES) f(\d+) ([\d.]+),([\d.]+) ([\d.]+),([\d.]+)", ln):
            prof[(int(v), ph)] = measure_profile(views[int(v)][int(f)], sx, sy,
                                                 (float(ax), float(ay)), (float(bx), float(by)))
        rcs = [p[0] for p in prof.values()]
        if all(rc == 0 for rc in rcs):
            L = max(p[1] for p in prof.values())
            edv, esv = volume(prof[(0, "ED")], prof[(1, "ED")], L), volume(prof[(0, "ES")], prof[(1, "ES")], L)
            ef = 100 * (edv - esv) / edv
            print(f"python: EDV {edv:.2f} ml ESV {esv:.2f} ml EF {ef:.2f}%")
            ok = abs(edv - ui["edv"]) < 0.05 and abs(esv - ui["esv"]) < 0.05 and abs(ef - ui["ef"]) < 0.05
        else:
            print("python profile rc", rcs)
            ok = False
    else:
        print("no biplane result in the log:")
        print("\n".join(log.splitlines()[-15:]))

    # 4. Leave the measurement, 3D tab, drag.
    mouse("click 1163 419")                        # 退出测量
    mouse("click 1217 87")                         # layout: A4C only (demo plays the long TED loops)
    time.sleep(5.0)
    shot("seg_a4c")
    mouse("click 1140 87")                         # layout: back to A2C + A4C
    mouse("click 470 28")                          # tab: shape (4 tabs)
    time.sleep(4.0)
    shot("shape_before")
    mouse("drag 300 400 460 400")                  # drag right: the front should turn to the right
    shot("shape_after_right")
    mouse("drag 360 300 360 420")                  # drag down
    shot("shape_after_down")
    mouse("click 360 400 right")                   # reset view
    mouse("click 470 28")                          # unpin: demo alternates again
    print("UI_MOUSE_CHECK_PASS" if ok else "UI_MOUSE_CHECK_FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
