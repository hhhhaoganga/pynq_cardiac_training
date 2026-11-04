"""Compile a .nnp integer program into the fused-block format of the PL CNN engine.

Engine model (cnn_engine.cpp implements exactly this):
  The program is a list of BLOCKs. One block = [E] -> D -> [P] -> [+R], computed one
  output row at a time; only the block input, the block output and the residual source
  live in DDR, everything in between stays in on-chip row buffers.
    E  e_mode 0 copy (block input rows go straight to the D line buffer)
              1 pointwise 1x1 conv (expand)
              2 stem: dense 3x3 conv on the RGBX image via on-chip im2col (27 -> 32 inputs)
    D  depthwise k x k (k <= 5), stride 1/2, TF SAME padding; an identity 1x1 when the
       block has no depthwise conv (weight 1, mult 2^30, shift 30)
    P  p_mode 0 copy (D output is the block output)
              1 pointwise conv, int8 codes out
              2 pointwise conv, raw int32 accumulators out (detector head, PS dequantises)
    R  r_mode 0 none, 1 direct, 2 maxpool 2x2/2 of the source, 3 nearest x2 upsample of
       the source:  y = clamp((p * ma + r * mb + 2^19) >> 20, lo, hi)
  Tensors in DDR: NHWC int8 codes, channels padded to multiples of 16 (one 128-bit
  vector = 16 lanes); the head output uses 16 x int32 per vector; the network input is
  RGBX (4 bytes per pixel). Padded lanes have zero weights/bias, so they stay 0.
  Pointwise weights are 16 out x TILE_IN in tiles of 5-bit signed values (80 * TILE_IN bits),
  ordered (og, ig, tile, pass); the array does 16 * TILE_IN MAC per cycle;
  8-bit layers (stem, head) are split as w = lo + 16*hi into two passes.
  Depthwise weights: one 5 tap x 16 lane word per (cg, ky), taps right-aligned in the
  5-wide sliding window (slot 5-k+kx).
  Params per stage per channel group: 16 x int32 bias, 16 x int32 mult, 16 x u8 shift.

Outputs (in <out>/<model>/):
  mem_init.bin   DDR image: descriptors at 0, params/weights, input image, zero tensors
  golden.bin     same image with every tensor filled from the integer reference
  checks.txt     one line per block: index out_byte_addr out_bytes kind
  layout.txt     human readable block list (shapes, modes, tensor ids)

Usage: python compile_nnp.py --nnp <dir with *.nnp> --golden <dir with *_in.u8> --out <dir>
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "hand_landmark"))
import nnp  # noqa: E402

# descriptor word indices (keep in sync with cnn_engine.hpp)
F = dict(
    e_mode=0, p_mode=1, r_mode=2, np_e=3, np_p=4,
    ih=5, iw=6, icg=7, in_sg=8,
    eh=9, ew=10, ecg=11, e_sg=12, e_lo=13, e_hi=14,
    dk=15, ds=16, dpt=17, dpl=18, dh=19, dw=20, d_sg=21, d_lo=22, d_hi=23,
    ocg=24, p_lo=25, p_hi=26, p_sg=27,
    rw=28, rcg=29, r_sg=30, ma=31, mb=32, a_lo=33, a_hi=34,
    spt=35, spl=36,
    in_addr=40, out_addr=41, res_addr=42, wt_addr=43, wd_addr=44, par_e=45,
    n_te=46, n_tp=47, par_d=48, par_p=49, wt_p=50,
)
# on-chip buffer limits (keep in sync with cnn_engine.hpp), in 128-bit vectors unless noted
LIMITS = dict(outh=64, lb_slot=832, pin=416, dwb=640, outb=320, resb=256, wt=0, wd=210, par=42, img_w=416)
DESC_WORDS = 64
NSLOT = 6
DW_TAPS = 5
DW_BEATS = 7
ALIGN = 64
TILE_IN = 8                    # inputs per pointwise tile (16 / TILE_IN tiles per input group)
TILE_BEATS = 16 * TILE_IN * 5 // 64
# The wt array is 80 * TILE_IN bits wide (18 RAMB36 up to a depth of 8192 / TILE_IN); a deeper
# one would double its block RAM. Blocks that would need more are split (see split_wide).
SPLIT_TILES = 8192 // TILE_IN
LIMITS["wt"] = SPLIT_TILES


def cg(c: int) -> int:
    return (c + 15) // 16


def n_pw_tiles(o) -> int:
    """Pointwise tiles that pw_tiles() emits for this pointwise conv op."""
    cin_pad = 32 if (o.k == 3 and o.cin == 3) else 16 * cg(o.cin)
    planes = 1 if np.abs(o.w).max() <= 15 else 2
    return cg(o.cout) * (cin_pad // 16) * (16 // TILE_IN) * planes


@dataclass
class Block:
    E: int | None = None
    D: int | None = None
    P: int | None = None
    add: int | None = None
    r_mode: int = 0
    r_src: int | None = None
    absorbed: list[int] = field(default_factory=list)
    inp: int = -1
    out: int = -1


def group(p: nnp.Program) -> list[Block]:
    cons: dict[int, list[int]] = {}
    prod: dict[int, int] = {}
    for i, op in enumerate(p.ops):
        prod[op.out] = i
        for t in op.ins:
            cons.setdefault(t, []).append(i)

    def only(t: int) -> int | None:
        c = cons.get(t, [])
        return c[0] if len(c) == 1 else None

    def is_pw(i):
        o = p.ops[i]
        return o.type in (nnp.CONV, nnp.CONV_F) and not o.depthwise and o.k == 1 and o.stride == 1

    def is_dw(i):
        o = p.ops[i]
        return o.type == nnp.CONV and o.depthwise

    used, blocks = set(), []
    for i, op in enumerate(p.ops):
        if i in used or op.type in (nnp.MAXPOOL, nnp.UPSAMPLE2, nnp.MEAN, nnp.FC_F):
            continue
        assert op.type in (nnp.CONV, nnp.CONV_F), (i, op.type)
        b = Block()
        if is_dw(i):
            b.D = i
        else:
            nxt = only(op.out)
            stem = op.k == 3 and op.cin == 3 and not op.depthwise
            if (stem or is_pw(i)) and op.type == nnp.CONV and nxt is not None and is_dw(nxt):
                b.E, b.D = i, nxt
            else:
                assert is_pw(i), i
                b.P = i
        if b.D is not None:
            nxt = only(p.ops[b.D].out)
            if nxt is not None and is_pw(nxt):
                b.P = nxt
        if b.P is not None and p.ops[b.P].type == nnp.CONV:
            nxt = only(p.ops[b.P].out)
            if nxt is not None and p.ops[nxt].type == nnp.ADD:
                a = p.ops[nxt]
                assert a.ins[0] == p.ops[b.P].out, nxt
                b.add = nxt
                src = a.ins[1]
                sp = prod.get(src)
                if sp is not None and p.ops[sp].type == nnp.MAXPOOL:
                    assert p.ops[sp].k == 2 and p.ops[sp].stride == 2
                    b.r_mode, b.r_src = 2, p.ops[sp].ins[0]
                    b.absorbed.append(sp)
                elif sp is not None and p.ops[sp].type == nnp.UPSAMPLE2:
                    b.r_mode, b.r_src = 3, p.ops[sp].ins[0]
                    b.absorbed.append(sp)
                else:
                    b.r_mode, b.r_src = 1, src
        first = next(x for x in (b.E, b.D, b.P) if x is not None)
        last = b.add if b.add is not None else (b.P if b.P is not None else b.D)
        b.inp, b.out = p.ops[first].ins[0], p.ops[last].out
        for x in (b.E, b.D, b.P, b.add, *b.absorbed):
            if x is not None:
                used.add(x)
        blocks.append(b)
    # every op must be covered, except the PS tail (mean / fc)
    for i, op in enumerate(p.ops):
        assert i in used or op.type in (nnp.MEAN, nnp.FC_F), ("op not mapped", i)
    # dependency order: a block runs once its input and residual source exist
    ready, order, todo = {p.input}, [], list(blocks)
    while todo:
        for b in todo:
            if b.inp in ready and (b.r_src is None or b.r_src in ready):
                order.append(b)
                ready.add(b.out)
                todo.remove(b)
                break
        else:
            raise RuntimeError("block graph has a cycle")
    return order


# ---------------------------------------------------------------------------- packing

def split_wide(p: nnp.Program, order: list[Block]) -> tuple[list[Block], dict[int, int]]:
    """Cut blocks whose pointwise weight tiles exceed SPLIT_TILES in two, so the engine's
    wt array keeps a depth of at most SPLIT_TILES and does not need two rows of block RAM:
        A = E, writing the expanded int8 codes to DDR
        B = copy + D + P, reading them back
    The codes are what D already consumes, so the DDR round trip is bit exact. Returns the
    new block list and {intermediate tensor: tensor whose codes it holds}."""
    out, mid_of = [], {}
    for b in order:
        n_te = n_pw_tiles(p.ops[b.E]) if b.E is not None else 0
        n_tp = n_pw_tiles(p.ops[b.P]) if b.P is not None else 0
        if n_te + n_tp <= SPLIT_TILES:
            out.append(b)
            continue
        assert b.E is not None and b.D is not None and n_te <= SPLIT_TILES and n_tp <= SPLIT_TILES,             "only an E fusion can exceed the tile budget"
        te = p.tensors[p.ops[b.E].out]                     # E's output, i.e. D's input
        mid = len(p.tensors)
        p.tensors.append(nnp.Tensor(te.h, te.w, te.c, te.dtype, te.scale, te.signed))
        mid_of[mid] = p.ops[b.E].out
        out.append(Block(E=b.E, inp=b.inp, out=mid))
        out.append(Block(D=b.D, P=b.P, add=b.add, r_mode=b.r_mode, r_src=b.r_src, inp=mid, out=b.out))
    return out, mid_of


def split8(w: np.ndarray) -> list[np.ndarray]:
    """5-bit planes: one plane if |w| <= 15, else w = lo + 16*hi (lo in [-8,7], hi in [-8,8])."""
    w = w.astype(np.int64)
    if np.abs(w).max() <= 15:
        return [w]
    lo = ((w + 8) & 15) - 8
    hi = (w - lo) >> 4
    assert np.abs(hi).max() <= 15 and np.all(lo + 16 * hi == w)
    return [lo, hi]


def pack_bits(vals: np.ndarray, bits: int, nbeats: int) -> bytes:
    v = 0
    for i, x in enumerate(vals.reshape(-1).tolist()):
        v |= (int(x) & ((1 << bits) - 1)) << (i * bits)
    return v.to_bytes(nbeats * 8, "little")


def pw_tiles(wmat: np.ndarray, cin_pad: int, cout_pad: int) -> tuple[bytes, int]:
    """wmat (cout, cin) int -> tiles ordered (og, ig, quarter, pass), each 16 out x TILE_IN in x 5 bit (o-major)."""
    full = np.zeros((cout_pad, cin_pad), np.int64)
    full[:wmat.shape[0], :wmat.shape[1]] = wmat
    planes = split8(full)
    out = []
    for og in range(cout_pad // 16):
        for ig in range(cin_pad // 16):
            for h in range(16 // TILE_IN):
                for pl in planes:
                    i0 = ig * 16 + h * TILE_IN
                    out.append(pack_bits(pl[og * 16:og * 16 + 16, i0:i0 + TILE_IN], 5, TILE_BEATS))
    return b"".join(out), len(planes)


def dw_words(w: np.ndarray | None, k: int, c_pad: int) -> bytes:
    """Per (cg, ky): DW_TAPS x 16 lanes x 5-bit weights in DW_BEATS words."""
    assert 1 <= k <= DW_TAPS, (k, DW_TAPS)
    full = np.zeros((DW_TAPS, DW_TAPS, c_pad), np.int64)
    if w is None:
        full[0, DW_TAPS - 1, :] = 1
    else:
        for ky in range(k):
            for kx in range(k):
                full[ky, DW_TAPS - k + kx, :w.shape[2]] = w[ky, kx]
    assert np.abs(full).max() <= 15
    out = []
    for g in range(c_pad // 16):
        for ky in range(DW_TAPS):
            out.append(pack_bits(full[ky, :, g * 16:g * 16 + 16], 5, DW_BEATS))
    return b"".join(out)


def params(bias, mult, shift, c_pad: int) -> bytes:
    """Per cg: 16 x i32 bias, 16 x i32 mult, 16 x u8 shift (18 beats)."""
    b = np.zeros(c_pad, "<i4"); m = np.zeros(c_pad, "<i4"); s = np.zeros(c_pad, np.uint8)
    n = len(bias)
    b[:n] = bias
    if mult is not None:
        m[:n] = mult; s[:n] = shift
    out = []
    for g in range(c_pad // 16):
        sl = slice(g * 16, g * 16 + 16)
        out += [b[sl].tobytes(), m[sl].tobytes(), s[sl].tobytes()]
    return b"".join(out)


def srange(signed: bool) -> tuple[int, int]:
    return (-127, 127) if signed else (0, 255)


def tensor_bytes(t: nnp.Tensor, is_input: bool) -> int:
    if is_input:
        return t.h * t.w * 4
    return t.h * t.w * cg(t.c) * (64 if t.dtype == 1 else 16)


def compile_program(p: nnp.Program, order: list[Block]):
    T, ops = p.tensors, p.ops
    for o in ops:
        if o.type in (nnp.CONV, nnp.CONV_F):
            w = np.abs(o.w.astype(np.int64))
            s = w.reshape(-1, w.shape[-1]).sum(0) if o.depthwise else w.reshape(w.shape[0], -1).sum(1)
            assert (s * 255 + np.abs(o.bias.astype(np.int64))).max() < 2 ** 23, "acc exceeds 24 bit"
    ddr_t = sorted({p.input} | {b.inp for b in order} | {b.out for b in order} |
                   {b.r_src for b in order if b.r_src is not None})
    blob = bytearray(DESC_WORDS * 4 * len(order))

    def put(data: bytes) -> int:
        blob.extend(b"\0" * (-len(blob) % ALIGN))
        a = len(blob)
        blob.extend(data)
        return a

    descs, use = [], {k: 0 for k in LIMITS}
    for b in order:
        d = np.zeros(DESC_WORDS, np.int64)
        tin = T[b.inp]
        stem = b.E is not None and ops[b.E].k == 3
        in_sg = b.inp != p.input and tin.signed
        d[F["ih"]], d[F["iw"]], d[F["in_sg"]] = tin.h, tin.w, in_sg
        d[F["icg"]] = 2 if stem else cg(tin.c)
        # ---- E
        if b.E is not None:
            e = ops[b.E]
            te = T[e.out]
            d[F["e_mode"]] = 2 if stem else 1
            d[F["eh"]], d[F["ew"]], d[F["ecg"]] = te.h, te.w, cg(te.c)
            d[F["e_sg"]], d[F["e_lo"]], d[F["e_hi"]] = e.lo < 0, e.lo, e.hi
            if stem:
                assert e.stride == 2 and e.cin == 3
                d[F["spt"]], d[F["spl"]] = e.pad_t, e.pad_l
                wm, cin_pad = e.w.reshape(e.cout, 27), 32
            else:
                wm, cin_pad = e.w.reshape(e.cout, e.cin), 16 * cg(e.cin)
            te_bytes, d[F["np_e"]] = pw_tiles(wm, cin_pad, 16 * cg(e.cout))
            d[F["par_e"]] = put(params(e.bias, e.mult, e.shift, 16 * cg(e.cout)))
        else:
            d[F["eh"]], d[F["ew"]], d[F["ecg"]] = tin.h, tin.w, cg(tin.c)
            d[F["e_sg"]] = in_sg
            d[F["e_lo"]], d[F["e_hi"]] = srange(in_sg)
            te_bytes = b""
        ecg = int(d[F["ecg"]])
        # ---- D
        if b.D is not None:
            o = ops[b.D]
            assert cg(o.cout) == ecg and o.k <= DW_TAPS and o.stride in (1, 2)
            d[F["dk"]], d[F["ds"]], d[F["dpt"]], d[F["dpl"]] = o.k, o.stride, o.pad_t, o.pad_l
            d[F["dh"]], d[F["dw"]] = T[o.out].h, T[o.out].w
            d[F["d_sg"]], d[F["d_lo"]], d[F["d_hi"]] = o.lo < 0, o.lo, o.hi
            d[F["wd_addr"]] = put(dw_words(o.w, o.k, 16 * ecg))
            d[F["par_d"]] = put(params(o.bias, o.mult, o.shift, 16 * ecg))
        else:
            d[F["dk"]], d[F["ds"]] = 1, 1
            d[F["dh"]], d[F["dw"]] = d[F["eh"]], d[F["ew"]]
            for a, s in (("d_sg", "e_sg"), ("d_lo", "e_lo"), ("d_hi", "e_hi")):
                d[F[a]] = d[F[s]]
            n = 16 * ecg
            d[F["wd_addr"]] = put(dw_words(None, 1, n))
            d[F["par_d"]] = put(params(np.zeros(n, np.int64), np.full(n, 1 << 30), np.full(n, 30), n))
        # ---- P
        if b.P is not None:
            o = ops[b.P]
            assert cg(o.cin) == ecg
            d[F["p_mode"]] = 1 if o.type == nnp.CONV else 2
            d[F["ocg"]] = cg(o.cout)
            if o.type == nnp.CONV:
                d[F["p_sg"]], d[F["p_lo"]], d[F["p_hi"]] = o.lo < 0, o.lo, o.hi
            tp_bytes, d[F["np_p"]] = pw_tiles(o.w.reshape(o.cout, o.cin), 16 * ecg, 16 * cg(o.cout))
            d[F["par_p"]] = put(params(o.bias, o.mult, o.shift, 16 * cg(o.cout)))
        else:
            d[F["ocg"]] = ecg
            for a, s in (("p_sg", "d_sg"), ("p_lo", "d_lo"), ("p_hi", "d_hi")):
                d[F[a]] = d[F[s]]
            tp_bytes = b""
        # ---- R
        d[F["r_mode"]] = b.r_mode
        d[F["a_lo"]], d[F["a_hi"]] = d[F["p_lo"]], d[F["p_hi"]]
        dh, dw_ = int(d[F["dh"]]), int(d[F["dw"]])
        if b.add is not None:
            a = ops[b.add]
            assert a.e[2] == nnp.ADD_SHIFT
            r = T[b.r_src]
            d[F["ma"]], d[F["mb"]], d[F["a_lo"]], d[F["a_hi"]] = a.e[0], a.e[1], a.lo, a.hi
            d[F["rw"]], d[F["rcg"]], d[F["r_sg"]] = r.w, cg(r.c), r.signed
            assert cg(r.c) == d[F["ocg"]]
            assert b.r_mode != 2 or cg(r.c) <= 8, "rd_pool keeps <= 8 channel groups"
            want = {1: (dh, dw_), 2: (dh, dw_), 3: (dh // 2, dw_ // 2)}[b.r_mode]
            got = (r.h // 2, r.w // 2) if b.r_mode == 2 else (r.h, r.w)
            assert got == want, (b.r_mode, got, want)
        to = T[b.out]
        assert (to.h, to.w) == (dh, dw_) and cg(to.c) == d[F["ocg"]]
        d[F["wt_addr"]] = put(te_bytes + tp_bytes)
        d[F["wt_p"]] = d[F["wt_addr"]] + len(te_bytes)
        d[F["n_te"]], d[F["n_tp"]] = len(te_bytes) // (8 * TILE_BEATS), len(tp_bytes) // (8 * TILE_BEATS)
        descs.append(d)
        # buffer usage
        # pin holds the E input row (copy blocks read straight into lb) or, for r_mode 2,
        # the first residual row before pooling
        pin_e = int(d[F["iw"]] * (1 if stem else d[F["icg"]])) if d[F["e_mode"]] else 0
        pin_r = int(d[F["rw"]] * d[F["rcg"]]) if b.r_mode == 2 else 0
        u = dict(lb_slot=int(d[F["ew"]]) * ecg, pin=max(pin_e, pin_r),
                 dwb=dw_ * ecg, outb=dw_ * int(d[F["ocg"]]) * (d[F["p_mode"]] == 1),
                 outh=dw_ * int(d[F["ocg"]]) * (d[F["p_mode"]] == 2),
                 resb=int(d[F["rw"]] * d[F["rcg"]]), wt=int(d[F["n_te"]] + d[F["n_tp"]]),
                 wd=ecg * DW_TAPS, par=max(ecg, int(d[F["ocg"]])), img_w=int(d[F["iw"]]) if stem else 0)
        for k, v in u.items():
            use[k] = max(use[k], v)
            assert v <= LIMITS[k], (k, v, LIMITS[k])
    # tensors after the code / weight region
    taddr = {}
    for t in ddr_t:
        blob.extend(b"\0" * (-len(blob) % ALIGN))
        taddr[t] = len(blob)
        blob.extend(b"\0" * tensor_bytes(T[t], t == p.input))
    blob.extend(b"\0" * (-len(blob) % ALIGN))
    for b, d in zip(order, descs):
        d[F["in_addr"]], d[F["out_addr"]] = taddr[b.inp], taddr[b.out]
        if b.r_src is not None:
            d[F["res_addr"]] = taddr[b.r_src]
    for i, d in enumerate(descs):
        assert np.all(np.abs(d) < 2 ** 31)
        blob[i * DESC_WORDS * 4:(i + 1) * DESC_WORDS * 4] = d.astype("<i4").tobytes()
    return blob, taddr, descs, use


def tensor_image(p: nnp.Program, env: dict, t: int) -> bytes:
    """Golden tensor in the DDR layout."""
    tt = p.tensors[t]
    x = env[t][0].permute(1, 2, 0)                                    # HWC
    if t == p.input:
        out = np.zeros((tt.h, tt.w, 4), np.uint8)
        out[..., :3] = x.numpy().astype(np.uint8)
        return out.tobytes()
    c_pad = 16 * cg(tt.c)
    if tt.dtype == 1:                                                 # head: recover int32 acc
        op = next(o for o in p.ops if o.out == t)
        acc = np.round(x.double().numpy() / op.deq.astype(np.float64)).astype(np.int64)
        assert np.abs(acc).max() < 2 ** 31
        out = np.zeros((tt.h, tt.w, c_pad), "<i4")
        out[..., :tt.c] = acc
        return out.tobytes()
    v = x.long().numpy()
    assert v.min() >= (-127 if tt.signed else 0) and v.max() <= (127 if tt.signed else 255)
    out = np.zeros((tt.h, tt.w, c_pad), np.uint8)
    out[..., :tt.c] = (v & 0xFF).astype(np.uint8)
    return out.tobytes()


def main() -> None:
    global DW_TAPS, DW_BEATS, NSLOT, TILE_IN, TILE_BEATS, SPLIT_TILES
    ap = argparse.ArgumentParser()
    ap.add_argument("--nnp", type=Path, required=True)
    ap.add_argument("--golden", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--models", default="knot,handdet,landmark")
    ap.add_argument("--profile", choices=("generic", "knot_dw3"), default="generic")
    ap.add_argument("--tile-in", type=int, choices=(4, 8), default=8)
    a = ap.parse_args()
    if a.tile_in != 8 and a.profile != "knot_dw3":
        raise ValueError('Nondefault tiling requires the generated knot_dw3 config')
    TILE_IN = a.tile_in
    TILE_BEATS = 16 * TILE_IN * 5 // 64
    SPLIT_TILES = 8192 // TILE_IN
    LIMITS['wt'] = SPLIT_TILES
    if a.profile == "knot_dw3":
        if a.models != "knot":
            raise ValueError("knot_dw3 requires --models knot; hand profiles remain separate")
        DW_TAPS, DW_BEATS, NSLOT = 3, 4, 4
    for name in a.models.split(","):
        p = nnp.read(a.nnp / f"{name}.nnp")
        ti = p.tensors[p.input]
        img = np.fromfile(a.golden / f"{name}_in.u8", np.uint8).reshape(ti.h, ti.w, 3)
        env = nnp.IntRef(p)(torch.from_numpy(img).permute(2, 0, 1).unsqueeze(0).long(), keep_all=True)["_env"]
        order, mid_of = split_wide(p, group(p))
        for mid, src in mid_of.items():
            env[mid] = env[src]
        blob, taddr, descs, use = compile_program(p, order)
        init, gold = bytearray(blob), bytearray(blob)
        for t, addr in taddr.items():
            data = tensor_image(p, env, t)
            gold[addr:addr + len(data)] = data
            if t == p.input:
                init[addr:addr + len(data)] = data
        od = a.out / name
        od.mkdir(parents=True, exist_ok=True)
        (od / "mem_init.bin").write_bytes(bytes(init))
        (od / "golden.bin").write_bytes(bytes(gold))
        lines, lay = [f"{len(order)} {len(blob)}"], []
        for i, (b, d) in enumerate(zip(order, descs)):
            to = p.tensors[b.out]
            n = tensor_bytes(to, False)
            kind = ("E%d" % d[F["e_mode"]]) + ("D%d" % d[F["dk"]]) + ("P%d" % d[F["p_mode"]]) + ("R%d" % b.r_mode)
            lines.append(f"{i} {taddr[b.out]} {n} {kind}")
            lay.append(f"blk {i:2d} {kind:10s} t{b.inp}->t{b.out} r=t{b.r_src} ops E{b.E} D{b.D} P{b.P} add{b.add} "
                       f"in {p.tensors[b.inp].h}x{p.tensors[b.inp].w}x{p.tensors[b.inp].c} "
                       f"e {d[F['ew']]}x{d[F['ecg']]}cg out {to.h}x{to.w}x{to.c} tiles {d[F['n_te']]}+{d[F['n_tp']]}")
        (od / "checks.txt").write_text("\n".join(lines) + "\n")
        (od / "layout.txt").write_text("\n".join(lay) + "\n")
        (od / "profile.json").write_text(json.dumps({"profile":a.profile,"dw_taps":DW_TAPS,
            "dw_beats":DW_BEATS,"nslot":NSLOT,"tile_in":TILE_IN,
            "buffer_use":{k:int(v) for k,v in use.items()}},indent=2))
        if a.profile == "knot_dw3":
            names = {"lb_slot":"LB_SLOT","pin":"PIN_MAX","dwb":"DWB_MAX","outb":"OUTB_MAX",
                     "outh":"OUTH_MAX","resb":"RESB_MAX","wt":"WT_MAX","wd":"WD_MAX",
                     "par":"PAR_MAX","img_w":"IMG_W"}
            header = ['#pragma once', '// Generated for this fixture; do not pair with generic packed weights.',
                      '#define CNN_DW_TAPS 3', '#define CNN_NSLOT 4', f'#define CNN_TILE_IN {TILE_IN}']
            header += [f'#define CNN_{names[k]} {max(1,v)}' for k,v in use.items()]
            (od / "knot_config.hpp").write_text('\n'.join(header)+'\n')
        print(f"{name}: {len(order)} blocks, image {len(blob) / 1e6:.2f} MB, buffer use {use}")


if __name__ == "__main__":
    main()
