"""Export the float32 (BN-folded) SE StreamSkipUNet for the ARM CPU baseline.

Same checkpoint the deployed W4A8 model was QAT-trained from
(runs/camus_stream_se_ablation_20260922/best.pt, float Dice 0.8833 on CAMUS val).
Writes:
  seg_float.bin  "SEGF" | u32 n_conv | per conv: u32 cout, cin, k | f32 w[cout][cin][k][k] | f32 b[cout]
                 order: enc1a enc1b enc2a enc2b enc3a enc3b enc4a enc4b temporal se1 se2
                        dec3p dec3a dec3b dec2p dec2a dec2b dec1p dec1a dec1b head
  frames.u8      N x 256 x 256 input frames (uint8, model orientation)
  ref_masks.u8   N x 256 x 256 argmax of the float model run as a stream (stream_step)
  ref_logits.f32 4 x 256 x 256 logits of the last frame
  macs.json      MAC count per layer for one stream step
    python export_float.py --seq data/processed/camus_stream_s_256/patient0200_4CH_image.npy --frames 30
"""
import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn.utils.fusion import fuse_conv_bn_eval

sys.path.insert(0, "/home/lizx/fpga_medseg")
from medical_segmentation.model_stream_skip import StreamSkipUNet  # noqa: E402

CKPT = "/home/lizx/fpga_medseg/runs/camus_stream_se_ablation_20260922/best.pt"


def fold(seq):
    """conv, bn, relu, conv, bn, relu -> [(conv_folded)]."""
    m = list(seq)
    out = []
    for i, x in enumerate(m):
        if isinstance(x, nn.Conv2d):
            bn = m[i + 1] if i + 1 < len(m) and isinstance(m[i + 1], nn.BatchNorm2d) else None
            out.append(fuse_conv_bn_eval(x.eval(), bn.eval()) if bn is not None else x)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seq", required=True)
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--out", type=Path, default=Path("."))
    a = ap.parse_args()
    net = StreamSkipUNet(num_classes=4, use_se=True)
    net.load_state_dict(torch.load(CKPT, map_location="cpu", weights_only=False)["model"])
    net.eval()
    convs = []
    for blk in (net.enc1, net.enc2, net.enc3, net.enc4):
        convs += fold(blk)
    convs += fold(net.temporal)
    convs += [net.se[1], net.se[3]]
    for up in (net.dec3, net.dec2, net.dec1):
        convs += fold(up.project) + fold(up.refine)
    convs.append(net.head)
    assert len(convs) == 21, len(convs)
    blob = bytearray(b"SEGF") + struct.pack("<I", len(convs))
    for c in convs:
        w = c.weight.detach().float().numpy().astype("<f4")
        b = (c.bias.detach().float().numpy() if c.bias is not None else np.zeros(w.shape[0])).astype("<f4")
        blob += struct.pack("<3I", w.shape[0], w.shape[1], w.shape[2]) + w.tobytes() + b.tobytes()
    (a.out / "seg_float.bin").write_bytes(blob)

    # Reference: the folded model must equal the original (eval BN); run the original as a stream.
    seq = np.load(a.seq)
    if seq.ndim == 3 and seq.shape[-1] == 256 and seq.shape[0] != 256:
        frames = seq[: a.frames]
    else:
        frames = np.moveaxis(seq, -1, 0)[: a.frames]
    frames = np.ascontiguousarray(frames.astype(np.uint8))
    assert frames.shape[1:] == (256, 256), frames.shape
    masks, state, logits = [], None, None
    with torch.no_grad():
        for f in frames:
            x = torch.from_numpy(f).float().div_(255.0)[None, None]
            logits, state = net.stream_step(x, state)
            masks.append(logits.argmax(1)[0].numpy().astype(np.uint8))
    frames.tofile(a.out / "frames.u8")
    np.stack(masks).tofile(a.out / "ref_masks.u8")
    logits[0].numpy().astype("<f4").tofile(a.out / "ref_logits.f32")

    macs = {}
    def hook(name):
        def f(m, i, o):
            macs[name] = macs.get(name, 0) + int(o.numel() * m.in_channels // m.groups * m.kernel_size[0] * m.kernel_size[1])
        return f
    hs = [m.register_forward_hook(hook(n)) for n, m in net.named_modules() if isinstance(m, nn.Conv2d)]
    with torch.no_grad():
        net.stream_step(torch.zeros(1, 1, 256, 256), None)
    for h in hs:
        h.remove()
    json.dump({"per_layer": macs, "total_mac_per_frame": sum(macs.values()),
               "params": sum(p.numel() for p in net.parameters()), "frames": len(frames), "source": a.seq},
              open(a.out / "macs.json", "w"), indent=1)
    print("exported", len(frames), "frames, MAC/frame", sum(macs.values()), "params", sum(p.numel() for p in net.parameters()))


if __name__ == "__main__":
    main()
