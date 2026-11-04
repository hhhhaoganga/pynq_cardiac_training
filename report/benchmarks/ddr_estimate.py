"""DDR traffic estimate of the PL segmentation (rm_seg) per frame, from tensor sizes.

Not measured: the static shell has no AXI performance monitor. Weights are in on-chip ROM
(pl_rom_se_candidate), activations INT8. Lower bound: frame in, mask out, skips + bottleneck
written once and read once, two history bottlenecks read. Upper bound: every layer output
written to DDR and read back once (the workspace has padded / skip / scratch regions).
"""
import json

FPS = 28.68          # measured (proto_check throughput)
HDMI = 1280 * 720 * 4 * 60   # VDMA XRGB8888 720p60 read, always on
c = (4, 8, 16, 32)
size = lambda ch, s: ch * s * s   # bytes at INT8
skips = size(c[0], 256) + size(c[1], 128) + size(c[2], 64)
bott = size(c[3], 32)
io = 2 * 256 * 256                 # frame in + mask out
lower = io + 2 * (skips + bott) + 2 * bott
layers = [size(c[0], 256)] * 2 + [size(c[1], 128)] * 2 + [size(c[2], 64)] * 2 + [size(c[3], 32)] * 2 + \
         [bott, size(c[2], 32), size(c[2] * 2, 64), size(c[2], 64), size(c[2], 64),
          size(c[1], 64), size(c[1] * 2, 128), size(c[1], 128), size(c[1], 128),
          size(c[0], 128), size(c[0] * 2, 256), size(c[0], 256), size(c[0], 256), size(4, 256)]
upper = io + 2 * sum(layers) + 2 * bott
r = {"assumptions": __doc__.strip(), "fps": FPS,
     "seg_bytes_per_frame": {"lower": lower, "upper": upper},
     "seg_MBps": {"lower": round(lower * FPS / 1e6, 1), "upper": round(upper * FPS / 1e6, 1)},
     "hdmi_vdma_MBps": round(HDMI / 1e6, 1),
     "hp_port_peak_MBps": {"64bit_at_100MHz": 800, "64bit_at_200MHz": 1600}}
json.dump(r, open("ddr_estimate.json", "w"), indent=1)
print(json.dumps({k: v for k, v in r.items() if k != "assumptions"}, indent=1))
