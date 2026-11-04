#!/usr/bin/env python3
"""End-to-end check of echo_demo over TCP (CMS1 protocol), run on the board or a PC.

1. seg:   8 golden frames (se_golden_8) as one V1 sequence -> masks vs
          masks_largest_all.bin (expect 0 mismatches), same order as check_shell_seg.py
2. shape: fixture cases via MSG_SHAPE -> codes vs expected.bin (expect 0)
3. seg again after the swap back, then a MODE request round trip
4. throughput: a CAMUS sequence streamed with 4 frames in flight

Usage: proto_check.py [--host 127.0.0.1] [--data DIR] [--cases N]
"""
import argparse
import json
import socket
import struct
import sys
import time
import zlib
from pathlib import Path

import numpy as np

HEADER = struct.Struct("!4sBBHIIHHBBHII")
RESULT_V1, RESULT_V2 = struct.Struct("!IIIIQQQQQQ"), struct.Struct("!IIIIQQQQQQ10I")
FRAME_META_V2 = struct.Struct("!6I")
MSG_FRAME, MSG_SHAPE, MSG_MODE, MSG_STATUS, MSG_RESULT, MSG_SHAPE_RESULT = 1, 3, 4, 0x81, 0x82, 0x83
SHAPE_IN = 2 * 224 * 224


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("board closed the connection")
        buf += chunk
    return bytes(buf)


def recv_msg(sock):
    h = HEADER.unpack(recv_exact(sock, HEADER.size))
    payload = recv_exact(sock, h[5])
    if h[0] != b"CMS1" or zlib.crc32(payload) & 0xFFFFFFFF != h[11]:
        raise ValueError("bad header or CRC")
    return h, payload


def frame_msg(frame, frame_id, flags, view, meta=None):
    payload = frame.astype(np.uint8).tobytes()
    version = 1
    if meta is not None:
        payload = FRAME_META_V2.pack(*meta) + payload
        version = 2
    return HEADER.pack(b"CMS1", version, MSG_FRAME, flags, frame_id, len(payload), 256, 256, 1, view, 0,
                       zlib.crc32(payload) & 0xFFFFFFFF, 0) + payload


def shape_msg(inp, frame_id, case, expected, label):
    meta = struct.pack("!II", case, 1) + expected.astype(np.int8).tobytes() + label.encode()[:32].ljust(32, b"\0") + bytes(8)
    payload = meta + inp.astype(np.uint8).tobytes()
    return HEADER.pack(b"CMS1", 2, MSG_SHAPE, 0, frame_id, len(payload), 224, 224, 2, 0, 0,
                       zlib.crc32(payload) & 0xFFFFFFFF, 0) + payload


def seg_run(sock, frames, expect, first_id, window=4, meta=None, view=4):
    """Stream frames with <window> in flight; returns (masks, results, seconds)."""
    n = len(frames)
    masks, metas = [None] * n, [None] * n
    sent = done = 0
    t0 = time.perf_counter()
    while done < n:
        while sent < n and sent - done < window:
            flags = (1 if sent == 0 else 0) | (2 if sent == n - 1 else 0)
            m = None if meta is None else (meta[0], sent, n, meta[1], meta[2], meta[3])
            sock.sendall(frame_msg(frames[sent], first_id + sent, flags, view, m))
            sent += 1
        h, payload = recv_msg(sock)
        assert h[2] == MSG_RESULT, h
        rs = RESULT_V2 if len(payload) == RESULT_V2.size + 65536 else RESULT_V1
        r = rs.unpack(payload[:rs.size])
        i = h[4] - first_id
        masks[i] = np.frombuffer(payload[rs.size:], np.uint8).reshape(256, 256)
        metas[i] = r
        done += 1
    return masks, metas, time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--data", default=str(Path(__file__).resolve().parent.parent / "data"))
    ap.add_argument("--golden", default="/home/xilinx/board_dfx/se_golden_8")
    ap.add_argument("--cases", type=int, default=150)
    args = ap.parse_args()
    d = Path(args.data)
    # The golden set is in the network's training orientation (transposed
    # apex-up); the protocol is apex-up, so swap x/y on both sides.
    frames = np.fromfile(Path(args.golden) / "frames.bin", np.uint8).reshape(-1, 256, 256)
    expect = np.fromfile(Path(args.golden) / "masks_largest_all.bin", np.uint8).reshape(-1, 256, 256)
    frames = np.ascontiguousarray(frames.transpose(0, 2, 1))
    expect = np.ascontiguousarray(expect.transpose(0, 2, 1))
    n_cases = json.loads((d / "shape_fixtures/manifest.json").read_text())["case_count"]
    inputs = np.fromfile(d / "shape_fixtures/inputs.bin", np.uint8).reshape(n_cases, SHAPE_IN)
    expected = np.fromfile(d / "shape_fixtures/expected.bin", np.int8).reshape(n_cases, 16)
    labels = (d / "shape_fixtures/labels.txt").read_text().split()

    sock = socket.create_connection((args.host, 5001), timeout=30)
    report, ok = {}, True
    fid = 1000

    def seg_golden(tag, window):
        nonlocal fid, ok
        masks, metas, secs = seg_run(sock, frames, expect, fid, window=window)
        fid += len(frames) + 10
        mism = [int(np.count_nonzero(m != e)) for m, e in zip(masks, expect)]
        codes = [r[0] for r in metas]
        report[tag] = dict(frames=len(frames), mismatch=mism, result_codes=codes,
                           board_ms=[round(r[9] / 1000, 2) for r in metas], seconds=round(secs, 3))
        ok &= sum(mism) == 0 and not any(codes)
        print(tag, json.dumps(report[tag]), flush=True)

    seg_golden("seg_serial", 1)
    seg_golden("seg_pipelined", 4)

    # shape
    t0 = time.perf_counter()
    mism, hw_us, svc_us, recon_us = 0, [], [], []
    for c in range(min(args.cases, n_cases)):
        sock.sendall(shape_msg(inputs[c], fid, c, expected[c], labels[c] if c < len(labels) else ""))
        fid += 1
        h, payload = recv_msg(sock)
        assert h[2] == MSG_SHAPE_RESULT, h
        code, case, _, hw, svc, rec = struct.unpack("!6I", payload[:24])
        got = np.frombuffer(payload[24:40], np.int8)
        mism += int(np.count_nonzero(got != expected[c])) + (code != 0) * 16
        hw_us.append(hw), svc_us.append(svc), recon_us.append(rec)
    report["shape"] = dict(cases=len(hw_us), code_mismatch=mism, hw_ms=round(np.mean(hw_us) / 1000, 3),
                           service_ms_first=round(svc_us[0] / 1000, 2),
                           service_ms_mean_rest=round(np.mean(svc_us[1:]) / 1000, 3) if len(svc_us) > 1 else None,
                           recon_ms=round(np.mean(recon_us) / 1000, 3), seconds=round(time.perf_counter() - t0, 2))
    ok &= mism == 0
    print("shape", json.dumps(report["shape"]), flush=True)

    seg_golden("seg_after_swap", 4)

    # explicit mode request
    for mode in (2, 1):
        t0 = time.perf_counter()
        sock.sendall(HEADER.pack(b"CMS1", 2, MSG_MODE, mode, fid, 0, 0, 0, 0, 0, 0, 0, 0))
        fid += 1
        h, payload = recv_msg(sock)
        assert h[2] == MSG_STATUS, h
        code, cur, swaps, swap_us = struct.unpack("!4I", payload[:16])
        report[f"mode{mode}"] = dict(code=code, mode=cur, swaps=swaps, swap_ms=swap_us / 1000,
                                     round_trip_ms=round((time.perf_counter() - t0) * 1000, 1))
        ok &= code == 0 and cur == mode
        print(f"mode{mode}", json.dumps(report[f"mode{mode}"]), flush=True)

    # throughput on a real sequence (V2 metadata)
    seq = d / "demo/patient0200_4CH_half_sequence_image.npy"
    if seq.exists():
        arr = np.load(seq)
        reps = np.concatenate([arr] * 4)
        masks, metas, secs = seg_run(sock, reps, None, fid, window=4, meta=(77, 709844, 585922, 10001))
        report["throughput"] = dict(frames=len(reps), fps=round(len(reps) / secs, 2),
                                    board_ms_mean=round(np.mean([r[9] for r in metas]) / 1000, 2),
                                    area_lv_first=metas[0][16:19])
        print("throughput", json.dumps(report["throughput"]), flush=True)
    sock.close()
    print("PROTO_CHECK_PASS" if ok else "PROTO_CHECK_FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
