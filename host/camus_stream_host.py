"""Tkinter host for the Zynq CAMUS continuous-frame TCP service."""

from __future__ import annotations

import argparse
import json
import queue
import re
import socket
import struct
import sys
import threading
import time
import tkinter as tk
import zlib
from pathlib import Path
from tkinter import filedialog, ttk

import numpy as np
from PIL import Image, ImageTk

ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent
# Demo sequences ship next to this script (host/data or host/camus_demo_groups).
DEFAULT_GROUP_DIR = next((d for d in (HERE / "camus_demo_groups", HERE / "data/camus_demo_groups",
                                      ROOT / "data/camus_demo_groups") if d.is_dir()),
                         ROOT / "data/camus_demo_groups")


def discover_test_groups(folder: Path) -> dict:
    groups = {}
    for path in sorted(folder.rglob("*_image.npy")):
        match = re.fullmatch(r"(.+?)_(2CH|4CH)(?:_.*)?_image", path.stem)
        if match:
            parent = path.parent.relative_to(folder)
            label = str(parent / match[1]) if str(parent) != "." else match[1]
            if parent.name == "TED_full_cycle":
                label = f"TED 完整周期 / {match[1]}"
            groups.setdefault(label, {})[match[2]] = path
    return groups


def manual_frame_indices(index: int, warmup: bool = True) -> list[int]:
    if index < 0:
        raise ValueError("frame index must not be negative")
    return list(range(max(0, index - 2) if warmup else index, index + 1))


MAGIC = b"CMS1"
VERSION = 1
VERSION_2 = 2
MSG_FRAME = 0x01
MSG_CONTROL = 0x02
MSG_RESULT = 0x82
FORMAT_GRAY8 = 1
FLAG_RESET_HISTORY = 1 << 0
FLAG_END_SEQUENCE = 1 << 1
HEADER = struct.Struct("!4sBBHIIHHBBHII")
RESULT_META = struct.Struct("!IIIIQQQQQQ")
FRAME_META_V2 = struct.Struct("!6I")
RESULT_META_V2 = struct.Struct("!IIIIQQQQQQ10I")
FRAME_SIZE = (256, 256)
FRAME_BYTES = FRAME_SIZE[0] * FRAME_SIZE[1]
# PYNQ-Z2 DFX board (pynq_dfx/board_app/src/proto.hpp): shape cases and PL
# module selection. The board swaps the partial bitstream on demand.
MSG_SHAPE = 0x03
MSG_MODE = 0x04
MSG_STATUS = 0x81
MSG_SHAPE_RESULT = 0x83
FORMAT_SHAPE2 = 2
MODE_SEG, MODE_SHAPE = 1, 2
SHAPE_INPUT_BYTES = 2 * 224 * 224
SHAPE_RESULT = struct.Struct("!6I16bi3I8x")
STATUS_RESULT = struct.Struct("!6I8x")
DEFAULT_SHAPE_DIR = next((p / "data/shape_fixtures" for p in Path(__file__).resolve().parents[:2]
                          if (p / "data/shape_fixtures").is_dir()), ROOT / "data/shape_fixtures")
# Light, plain theme for the Tk window.
UI_FONT = "Microsoft YaHei UI"
BG, CARD, BAR, EDGE = "#ECEFF3", "#FFFFFF", "#FFFFFF", "#D5DBE3"
FG, MUTED, ACCENT, OK, IMG_BG = "#1F2937", "#5B6676", "#005BAC", "#12804A", "#101318"
PREVIEW = 440
SOURCES = ("CAMUS 半周期 (A2C + A4C)", "TED 完整周期 (A4C)", "自选目录…", "打开单个文件…")
COLORS = np.asarray(
    [[0, 0, 0], [235, 64, 52], [50, 205, 90], [55, 125, 235]],
    dtype=np.uint8,
)


def recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("board closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def build_frame_message(
    frame: np.ndarray,
    frame_id: int,
    flags: int,
    view_id: int,
    timestamp_ms: int | None = None,
    *,
    sequence_metadata: dict | None = None,
) -> bytes:
    image = np.asarray(frame, dtype=np.uint8)
    if image.shape != (FRAME_SIZE[1], FRAME_SIZE[0]):
        raise ValueError(f"expected a 256 x 256 frame, got {image.shape}")
    if view_id not in (2, 4):
        raise ValueError(f"unsupported CAMUS view ID {view_id}")
    payload = image.tobytes(order="C")
    version = VERSION
    if sequence_metadata is not None:
        m = sequence_metadata
        values = tuple(int(m.get(k, 0)) for k in (
            "sequence_id", "frame_index", "frame_count", "spacing_x_nm",
            "spacing_y_nm", "study_id"))
        if any(v < 0 or v > 0xFFFFFFFF for v in values):
            raise ValueError("sequence metadata outside uint32")
        if values[2] == 0 or values[1] >= values[2]:
            raise ValueError("invalid sequence frame index/count")
        if bool(values[3]) != bool(values[4]):
            raise ValueError("both spacing values must be known or unknown")
        payload = FRAME_META_V2.pack(*values) + payload
        version = VERSION_2
    if timestamp_ms is None:
        timestamp_ms = int(time.monotonic() * 1000)
    header = HEADER.pack(
        MAGIC,
        version,
        MSG_FRAME,
        flags,
        frame_id,
        len(payload),
        FRAME_SIZE[0],
        FRAME_SIZE[1],
        FORMAT_GRAY8,
        view_id,
        0,
        zlib.crc32(payload) & 0xFFFFFFFF,
        timestamp_ms & 0xFFFFFFFF,
    )
    return header + payload


def parse_result_message(header: bytes, payload: bytes) -> tuple[int, np.ndarray, tuple[int, ...]]:
    if len(header) != HEADER.size:
        raise ValueError(f"expected {HEADER.size} header bytes, got {len(header)}")
    fields = HEADER.unpack(header)
    magic, version, msg_type, _, frame_id, payload_len, width, height, fmt, _, _, crc, _ = fields
    if magic != MAGIC or version not in (VERSION, VERSION_2) or msg_type != MSG_RESULT:
        raise ValueError("invalid result header")
    if width != 256 or height != 256 or fmt != FORMAT_GRAY8:
        raise ValueError("unsupported result shape")
    result_struct = RESULT_META_V2 if version == VERSION_2 else RESULT_META
    if payload_len != result_struct.size + FRAME_BYTES or len(payload) != payload_len:
        raise ValueError("invalid result payload length")
    if zlib.crc32(payload) & 0xFFFFFFFF != crc:
        raise ValueError(f"result CRC mismatch for frame {frame_id}")
    meta = result_struct.unpack(payload[:result_struct.size])
    if meta[2] != frame_id:
        raise ValueError("result frame ID mismatch")
    mask = np.frombuffer(payload[result_struct.size:], dtype=np.uint8).reshape(256, 256).copy()
    if np.any(mask > 3):
        raise ValueError("invalid mask class")
    return frame_id, mask, meta


def load_sequence_metadata(path: Path, frame_count: int) -> dict:
    """Sidecar spacing is already expressed on the network's 256x256 grid."""
    sidecar = path.with_suffix(".metadata.json")
    metadata = json.loads(sidecar.read_text(encoding="utf-8")) if sidecar.exists() else {}
    if metadata.get("frame_count", frame_count) != frame_count:
        raise ValueError("sidecar frame count does not match the sequence")
    return {
        "sequence_id": 0, "frame_index": 0, "frame_count": frame_count,
        "spacing_x_nm": int(metadata.get("spacing_x_nm", 0)),
        "spacing_y_nm": int(metadata.get("spacing_y_nm", 0)),
        "study_id": int(metadata.get("study_id", 0)),
        "view_id": metadata.get("view_id"),
    }


def normalize_frame(frame: np.ndarray) -> np.ndarray:
    values = np.asarray(frame).squeeze()
    if values.ndim != 2:
        raise ValueError(f"expected a 2-D frame, got {values.shape}")
    if values.dtype == np.uint8:
        # The unified training cache already defines the intensity contract.
        scaled = values
    else:
        values = values.astype(np.float32)
        finite = values[np.isfinite(values)]
        if finite.size == 0:
            scaled = np.zeros(values.shape, dtype=np.uint8)
        else:
            lo, hi = np.percentile(finite, (0.5, 99.5))
            if hi <= lo:
                lo, hi = float(finite.min()), float(finite.max())
            if hi <= lo:
                scaled = np.zeros(values.shape, dtype=np.uint8)
            else:
                values = np.nan_to_num(values, nan=lo, posinf=hi, neginf=lo)
                scaled = np.clip((values - lo) * 255.0 / (hi - lo), 0, 255).astype(
                    np.uint8
                )
    return np.asarray(
        Image.fromarray(scaled).resize(FRAME_SIZE, Image.Resampling.BILINEAR),
        dtype=np.uint8,
    )


def load_frames(path: Path) -> list[np.ndarray]:
    if path.is_dir():
        files = sorted(
            p
            for p in path.iterdir()
            if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}
        )
        if not files:
            raise ValueError("the selected directory contains no supported images")
        return [normalize_frame(np.asarray(Image.open(p).convert("L"))) for p in files]

    lower_name = path.name.lower()
    if lower_name.endswith(".npy"):
        array = np.load(path, mmap_mode="r")
    elif lower_name.endswith(".npz"):
        archive = np.load(path)
        key = next((name for name in archive.files if "image" in name.lower()), archive.files[0])
        array = archive[key]
    elif lower_name.endswith(".nii") or lower_name.endswith(".nii.gz"):
        import nibabel as nib

        array = np.asarray(nib.load(str(path)).dataobj).squeeze()
        if array.ndim == 2:
            array = array[..., None]
        if array.ndim != 3:
            raise ValueError(f"expected CAMUS NIfTI [X,Y,T], got {array.shape}")
        # Match camus_to_upright in the training-cache builder, not a display-only flip.
        frames_xy = np.moveaxis(array, -1, 0)
        array = np.flip(np.rot90(frames_xy, k=3, axes=(1, 2)), axis=2)
        array = np.clip(np.rint(array), 0, 255).astype(np.uint8)
        return [normalize_frame(frame) for frame in array]
    else:
        image = Image.open(path)
        frames = []
        try:
            while True:
                frames.append(normalize_frame(np.asarray(image.convert("L"))))
                image.seek(image.tell() + 1)
        except EOFError:
            pass
        return frames

    array = np.asarray(array)
    array = np.squeeze(array)
    if array.ndim == 2:
        return [normalize_frame(array)]
    if array.ndim != 3:
        raise ValueError(f"expected T x H x W or H x W x T, got {array.shape}")
    if array.shape[-1] < min(array.shape[0], array.shape[1]):
        array = np.moveaxis(array, -1, 0)
    return [normalize_frame(array[index]) for index in range(array.shape[0])]


def make_overlay(frame: np.ndarray, mask: np.ndarray) -> np.ndarray:
    rgb = np.repeat(frame[..., None], 3, axis=2).astype(np.uint16)
    for class_id in range(1, 4):
        selected = mask == class_id
        color = COLORS[class_id].astype(np.uint16)
        rgb[selected] = (rgb[selected] * 95 + color * 160 + 127) // 255
    return rgb.astype(np.uint8)


class CamusStreamApp:
    def __init__(
        self,
        root: tk.Tk,
        host: str,
        port: int,
        sequence: Path | None = None,
        autostart: bool = False,
        fps: float = 30.0,
        view: str = "2CH",
        rotation_degrees: int = 0,
        mirror_x: bool = False,
        mirror_y: bool = False,
    ) -> None:
        self.root = root
        self.root.title("超声心动图 FPGA 上位机 · PYNQ-Z2")
        self.root.geometry("1300x820")
        self.root.minsize(1240, 760)
        self.mode_var = tk.IntVar(value=MODE_SEG)
        self.source_var = tk.StringVar(value=SOURCES[0])
        self.conn_var = tk.StringVar(value="○ 未连接")
        self.orient_var = tk.StringVar()
        self.shape_source_var = tk.StringVar(value="未载入病例")
        self.shape_period_var = tk.DoubleVar(value=0.8)
        self.group_dir = DEFAULT_GROUP_DIR
        self.host_var = tk.StringVar(value=host)
        self.port_var = tk.IntVar(value=port)
        self.fps_var = tk.DoubleVar(value=fps)
        self.view_var = tk.StringVar(value=view)
        self.rotation_degrees = rotation_degrees % 360
        self.rotation_var = tk.StringVar()
        self.mirror_x = mirror_x
        self.mirror_y = mirror_y
        self.mirror_var = tk.StringVar()
        self.loop_var = tk.BooleanVar(value=True)
        self.path_var = tk.StringVar(value="未加载序列")
        self.status_var = tk.StringVar(value="未连接")
        self.stats_var = tk.StringVar(value="TX 0  RX 0  In-flight 0")
        self.group_var = tk.StringVar()
        self.frame_var = tk.IntVar(value=1)
        self.frame_total_var = tk.StringVar(value="/ 0")
        self.warmup_var = tk.BooleanVar(value=True)
        self.input_title = tk.StringVar(value="选中帧预览")
        self.output_title = tk.StringVar(value="尚未推理")
        self.groups = {}
        self.sequence_path = None
        self.selection_generation = 0
        self.send_lock = threading.Lock()
        self.last_result = None
        self.sock: socket.socket | None = None
        self.raw_frames: list[np.ndarray] = []
        self.frames: list[np.ndarray] = []
        self.pending: dict[int, tuple[float, np.ndarray]] = {}
        self.pending_lock = threading.Lock()
        self.sequence_metadata = {}
        self.play_generation = 0
        self.result_queue: queue.Queue[tuple[int, np.ndarray, np.ndarray, tuple[int, ...], float]] = queue.Queue()
        self.stop_event = threading.Event()
        self.play_event = threading.Event()
        # 3 in flight keeps the board's PL pipeline full (measured 28.5 fps at a
        # 30 fps source, same as 4) with ~35 ms less latency; 2 drops to ~24 fps.
        self.window = threading.BoundedSemaphore(3)
        self.aux_queue: queue.Queue = queue.Queue()
        self.shape_inputs: np.ndarray | None = None
        self.shape_expected: np.ndarray | None = None
        self.shape_labels: list[str] = []
        self.shape_index_var = tk.IntVar(value=1)
        self.shape_total_var = tk.StringVar(value="/ 0")
        self.shape_status_var = tk.StringVar(value="形状重建：未加载病例")
        self.pl_status_var = tk.StringVar(value="PL 模块：未知")
        self.shape_play = threading.Event()
        self.shape_sent: dict[int, float] = {}
        self.tx_count = 0
        self.rx_count = 0
        self.next_frame_id = 0
        self.input_photo: ImageTk.PhotoImage | None = None
        self.overlay_photo: ImageTk.PhotoImage | None = None
        self._build_ui()
        self.refresh_groups()
        if DEFAULT_SHAPE_DIR.is_dir():
            self.load_shape_cases(DEFAULT_SHAPE_DIR)
        self.root.after(10, self._poll_results)
        self.root.after(20, self._poll_aux)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        if sequence is not None:
            self.load_sequence(sequence)
        elif self.groups:
            self.select_group()
        if autostart:
            self.root.after(300, self.start)

    # ---- layout: left = steps (connect, mode, input, run), right = images ----
    def _style(self) -> None:
        self.root.configure(bg=BG)
        style = ttk.Style(self.root)
        style.theme_use("clam")
        base = (UI_FONT, 10)
        style.configure(".", background=BG, foreground=FG, font=base)
        style.configure("TFrame", background=BG)
        style.configure("Card.TFrame", background=CARD, relief="solid", borderwidth=1)
        style.configure("CardRow.TFrame", background=CARD)
        style.configure("Card.TLabel", background=CARD, foreground=FG)
        style.configure("Muted.TLabel", background=CARD, foreground=MUTED)
        style.configure("Step.TLabel", background=CARD, foreground=FG, font=(UI_FONT, 11, "bold"))
        style.configure("Title.TLabel", background=BG, foreground=FG, font=(UI_FONT, 15, "bold"))
        style.configure("Sub.TLabel", background=BG, foreground=MUTED)
        style.configure("Panel.TLabel", background=CARD, foreground=FG, font=(UI_FONT, 10, "bold"))
        style.configure("Status.TLabel", background=BAR, foreground=MUTED, padding=(12, 5))
        style.configure("TButton", padding=(10, 4), background="#F3F5F8", bordercolor=EDGE)
        style.map("TButton", background=[("active", "#E6ECF3")])
        style.configure("Accent.TButton", background=ACCENT, foreground="white", bordercolor=ACCENT)
        style.map("Accent.TButton", background=[("active", "#0A4F94"), ("disabled", "#9DB6D3")])
        style.configure("Card.TRadiobutton", background=CARD, foreground=FG)
        style.configure("Card.TCheckbutton", background=CARD, foreground=FG)
        style.map("Card.TRadiobutton", background=[("active", CARD)])
        style.map("Card.TCheckbutton", background=[("active", CARD)])
        style.configure("TCombobox", padding=3)
        style.configure("Horizontal.TScale", background=CARD)

    def _card(self, parent, title: str) -> ttk.Frame:
        card = ttk.Frame(parent, style="Card.TFrame", padding=(12, 8, 12, 10))
        card.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(card, text=title, style="Step.TLabel").pack(anchor=tk.W, pady=(0, 6))
        return card

    def _row(self, parent) -> ttk.Frame:
        row = ttk.Frame(parent, style="CardRow.TFrame")
        row.pack(fill=tk.X, pady=2)
        return row

    def _build_ui(self) -> None:
        self._style()
        head = ttk.Frame(self.root, padding=(16, 10, 16, 6))
        head.pack(fill=tk.X)
        ttk.Label(head, text="超声心动图 FPGA 上位机", style="Title.TLabel").pack(side=tk.LEFT)
        ttk.Label(head, text="PYNQ-Z2 · 网口 TCP 5001 · 心腔分割 / 三维形状重建",
                  style="Sub.TLabel").pack(side=tk.LEFT, padx=12, pady=(4, 0))

        status = ttk.Frame(self.root)
        status.pack(side=tk.BOTTOM, fill=tk.X)
        ttk.Label(status, textvariable=self.status_var, style="Status.TLabel").pack(side=tk.LEFT)
        ttk.Label(status, textvariable=self.stats_var, style="Status.TLabel").pack(side=tk.RIGHT)

        body = ttk.Frame(self.root, padding=(16, 0, 16, 10))
        body.pack(fill=tk.BOTH, expand=True)
        side = ttk.Frame(body)
        side.pack(side=tk.LEFT, fill=tk.Y)
        main = ttk.Frame(body)
        main.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0))

        # 1 connection
        card = self._card(side, "1  连接板卡")
        row = self._row(card)
        ttk.Label(row, text="IP", style="Card.TLabel").pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=self.host_var, width=15).pack(side=tk.LEFT, padx=(6, 6))
        ttk.Label(row, text="端口", style="Card.TLabel").pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=self.port_var, width=6).pack(side=tk.LEFT, padx=(6, 0))
        row = self._row(card)
        ttk.Button(row, text="连接", style="Accent.TButton", command=self.connect).pack(side=tk.LEFT)
        ttk.Button(row, text="断开", command=self.disconnect).pack(side=tk.LEFT, padx=6)
        self.conn_label = tk.Label(row, textvariable=self.conn_var, bg=CARD, fg=MUTED, font=(UI_FONT, 10))
        self.conn_label.pack(side=tk.LEFT, padx=6)
        ttk.Label(card, textvariable=self.pl_status_var, style="Muted.TLabel").pack(anchor=tk.W, pady=(4, 0))

        # 2 mode
        card = self._card(side, "2  功能模式")
        row = self._row(card)
        ttk.Radiobutton(row, text="心腔分割  (rm_seg)", value=MODE_SEG, variable=self.mode_var,
                        style="Card.TRadiobutton", command=self.select_mode).pack(side=tk.LEFT)
        ttk.Radiobutton(row, text="三维形状重建  (rm_shape)", value=MODE_SHAPE, variable=self.mode_var,
                        style="Card.TRadiobutton", command=self.select_mode).pack(side=tk.LEFT, padx=(12, 0))
        ttk.Label(card, text="选择后板卡切换对应 PL 部分重配置模块", style="Muted.TLabel").pack(anchor=tk.W)

        # 3 + 4 depend on the mode
        self.seg_side = ttk.Frame(side)
        self.shape_side = ttk.Frame(side)
        self._build_seg_side(self.seg_side)
        self._build_shape_side(self.shape_side)
        self.seg_side.pack(fill=tk.X)

        # right: input / result images
        self.preview = ttk.Frame(main, style="Card.TFrame", padding=12)
        self.preview.pack(fill=tk.BOTH, expand=True)
        ttk.Label(self.preview, textvariable=self.path_var, style="Muted.TLabel").pack(anchor=tk.W, pady=(0, 6))
        pics = ttk.Frame(self.preview, style="CardRow.TFrame")
        pics.pack(fill=tk.BOTH, expand=True)
        input_panel = ttk.Frame(pics, style="CardRow.TFrame")
        overlay_panel = ttk.Frame(pics, style="CardRow.TFrame")
        input_panel.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 6))
        overlay_panel.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(6, 0))
        ttk.Label(input_panel, textvariable=self.input_title, style="Panel.TLabel").pack(anchor=tk.W, pady=(0, 4))
        ttk.Label(overlay_panel, textvariable=self.output_title, style="Panel.TLabel").pack(anchor=tk.W, pady=(0, 4))
        self.input_label = tk.Label(input_panel, bg=IMG_BG, width=PREVIEW, height=PREVIEW)
        self.overlay_label = tk.Label(overlay_panel, bg=IMG_BG, width=PREVIEW, height=PREVIEW)
        self.input_label.pack(anchor=tk.NW)
        self.overlay_label.pack(anchor=tk.NW)
        self.legend = ttk.Frame(overlay_panel, style="CardRow.TFrame")
        self.legend.pack(anchor=tk.W, pady=(8, 0))
        for label, color in (("左心室 LV", "#EB4034"), ("心肌 MYO", "#32CD5A"), ("左心房 LA", "#377DEB")):
            tk.Label(self.legend, text="  ", bg=color).pack(side=tk.LEFT, padx=(0, 4))
            ttk.Label(self.legend, text=label, style="Card.TLabel").pack(side=tk.LEFT, padx=(0, 14))
        ttk.Label(self.preview, textvariable=self.shape_status_var, style="Muted.TLabel",
                  wraplength=900, justify=tk.LEFT).pack(anchor=tk.W, pady=(8, 0))
        self._update_rotation_label()
        self._update_mirror_label()
        self.select_mode(send=False)

    def _build_seg_side(self, side) -> None:
        card = self._card(side, "3  输入数据")
        row = self._row(card)
        ttk.Label(row, text="数据集", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        self.source_box = ttk.Combobox(row, textvariable=self.source_var, state="readonly", width=30,
                                       values=SOURCES)
        self.source_box.pack(side=tk.LEFT, padx=(4, 0))
        self.source_box.bind("<<ComboboxSelected>>", lambda _: self.select_source())
        row = self._row(card)
        ttk.Label(row, text="病例", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        self.group_box = ttk.Combobox(row, textvariable=self.group_var, state="readonly", width=20)
        self.group_box.pack(side=tk.LEFT, padx=(4, 6))
        self.group_box.bind("<<ComboboxSelected>>", lambda _: self.select_group())
        self.view_box = ttk.Combobox(row, values=("2CH", "4CH"), textvariable=self.view_var,
                                     state="readonly", width=6)
        self.view_box.pack(side=tk.LEFT)
        self.view_box.bind("<<ComboboxSelected>>", lambda _: self.select_view())
        row = self._row(card)
        ttk.Button(row, text="打开目录…", command=self.choose_group_dir).pack(side=tk.LEFT)
        ttk.Button(row, text="打开文件…", command=self.open_sequence).pack(side=tk.LEFT, padx=6)
        ttk.Label(card, text="文件：.npy / .npz / .nii(.gz) / 图像目录；2CH=A2C，4CH=A4C",
                  style="Muted.TLabel").pack(anchor=tk.W, pady=(2, 0))
        row = self._row(card)
        ttk.Label(row, text="方向", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        ttk.Button(row, text="↺90°", width=5, command=lambda: self.rotate_input(-90)).pack(side=tk.LEFT, padx=(4, 2))
        ttk.Button(row, text="↻90°", width=5, command=lambda: self.rotate_input(90)).pack(side=tk.LEFT, padx=2)
        ttk.Button(row, text="左右", width=5, command=lambda: self.toggle_mirror("x")).pack(side=tk.LEFT, padx=2)
        ttk.Button(row, text="上下", width=5, command=lambda: self.toggle_mirror("y")).pack(side=tk.LEFT, padx=2)
        ttk.Button(row, text="复位", width=5, command=self.reset_orientation).pack(side=tk.LEFT, padx=2)
        ttk.Label(card, textvariable=self.orient_var, style="Muted.TLabel").pack(anchor=tk.W)

        card = self._card(side, "4  运行")
        row = self._row(card)
        ttk.Label(row, text="帧率", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        ttk.Combobox(row, textvariable=self.fps_var, values=(5, 10, 15, 20, 25, 30), width=5).pack(side=tk.LEFT, padx=(4, 4))
        ttk.Label(row, text="帧/秒", style="Card.TLabel").pack(side=tk.LEFT)
        ttk.Checkbutton(row, text="循环播放", variable=self.loop_var, style="Card.TCheckbutton").pack(side=tk.LEFT, padx=(14, 0))
        row = self._row(card)
        ttk.Button(row, text="▶ 播放序列", style="Accent.TButton", command=self.start).pack(side=tk.LEFT)
        ttk.Button(row, text="暂停", command=self.stop).pack(side=tk.LEFT, padx=6)
        ttk.Button(row, text="单帧推理", command=self.test_once).pack(side=tk.LEFT)
        row = self._row(card)
        ttk.Label(row, text="帧", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        ttk.Button(row, text="◀", width=3, command=lambda: self.step_frame(-1)).pack(side=tk.LEFT, padx=(4, 2))
        self.frame_spin = ttk.Spinbox(row, from_=1, to=1, textvariable=self.frame_var, width=5, command=self.seek_frame)
        self.frame_spin.pack(side=tk.LEFT)
        self.frame_spin.bind("<Return>", lambda _: self.seek_frame())
        ttk.Label(row, textvariable=self.frame_total_var, style="Card.TLabel").pack(side=tk.LEFT, padx=4)
        ttk.Button(row, text="▶", width=3, command=lambda: self.step_frame(1)).pack(side=tk.LEFT, padx=2)
        ttk.Checkbutton(row, text="补齐前两帧", variable=self.warmup_var, style="Card.TCheckbutton").pack(side=tk.LEFT, padx=(8, 0))
        self.frame_scale = ttk.Scale(card, from_=1, to=1, command=self._scale_frame)
        self.frame_scale.pack(fill=tk.X, pady=(4, 2))
        self.frame_scale.bind("<ButtonRelease-1>", lambda _: self.seek_frame())
        ttk.Button(card, text="保存当前结果…", command=self.save_result).pack(anchor=tk.W, pady=(4, 0))

    def _build_shape_side(self, side) -> None:
        card = self._card(side, "3  输入数据")
        row = self._row(card)
        ttk.Button(row, text="载入病例目录…", command=self.choose_shape_dir).pack(side=tk.LEFT)
        ttk.Label(card, text="目录内需 inputs.bin / manifest.json（expected.bin 可选）",
                  style="Muted.TLabel").pack(anchor=tk.W, pady=(2, 0))
        ttk.Label(card, textvariable=self.shape_source_var, style="Muted.TLabel").pack(anchor=tk.W)
        row = self._row(card)
        ttk.Label(row, text="病例", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        ttk.Spinbox(row, from_=1, to=9999, textvariable=self.shape_index_var, width=6).pack(side=tk.LEFT, padx=(4, 4))
        ttk.Label(row, textvariable=self.shape_total_var, style="Card.TLabel").pack(side=tk.LEFT)

        card = self._card(side, "4  运行")
        row = self._row(card)
        ttk.Label(row, text="间隔", style="Card.TLabel", width=6).pack(side=tk.LEFT)
        ttk.Combobox(row, textvariable=self.shape_period_var, values=(0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 3.0),
                     width=5).pack(side=tk.LEFT, padx=(4, 4))
        ttk.Label(row, text="秒/例", style="Card.TLabel").pack(side=tk.LEFT)
        row = self._row(card)
        ttk.Button(row, text="▶ 连续重建", style="Accent.TButton", command=self.shape_start).pack(side=tk.LEFT)
        ttk.Button(row, text="停止", command=self.shape_play.clear).pack(side=tk.LEFT, padx=6)
        ttk.Button(row, text="单例重建", command=self.shape_once).pack(side=tk.LEFT)
        ttk.Label(card, text="三维网格显示在板卡 HDMI 画面上", style="Muted.TLabel").pack(anchor=tk.W, pady=(4, 0))

    def select_mode(self, send: bool = True) -> None:
        shape = self.mode_var.get() == MODE_SHAPE
        self.stop()
        self.shape_play.clear()
        (self.seg_side if shape else self.shape_side).pack_forget()
        (self.shape_side if shape else self.seg_side).pack(fill=tk.X)
        if shape:
            self.legend.pack_forget()
            self.input_title.set("形状网络输入 · 两视角轮廓")
            self.output_title.set("—")
            self._show_shape_input()
        else:
            self.legend.pack(anchor=tk.W, pady=(8, 0))
            if self.frames:
                self.seek_frame()
        if send and self.sock is not None:
            self.request_mode(self.mode_var.get())

    def _show_shape_input(self) -> None:
        if self.shape_inputs is None:
            self._show_blank()
            return
        index = max(self.shape_index_var.get() - 1, 0) % len(self.shape_inputs)
        views = self.shape_inputs[index].reshape(2, 224, 224)
        a = Image.fromarray(np.clip(views[0].astype(np.uint16) * 2, 0, 255).astype(np.uint8))
        b = Image.fromarray(np.clip(views[1].astype(np.uint16) * 2, 0, 255).astype(np.uint8))
        self.input_photo = ImageTk.PhotoImage(a.resize((PREVIEW, PREVIEW), Image.Resampling.NEAREST))
        self.overlay_photo = ImageTk.PhotoImage(b.resize((PREVIEW, PREVIEW), Image.Resampling.NEAREST))
        self.input_label.configure(image=self.input_photo)
        self.overlay_label.configure(image=self.overlay_photo)
        label = self.shape_labels[index] if index < len(self.shape_labels) else f"case {index}"
        self.input_title.set(f"病例 {index + 1} · {label} · 视角 8")
        self.output_title.set(f"病例 {index + 1} · {label} · 视角 6")

    def _show_blank(self) -> None:
        blank = ImageTk.PhotoImage(Image.new("RGB", (PREVIEW, PREVIEW), IMG_BG))
        self.input_photo = self.overlay_photo = blank
        self.input_label.configure(image=blank)
        self.overlay_label.configure(image=blank)

    def reset_orientation(self) -> None:
        self.mirror_x = self.mirror_y = False
        self.set_rotation(0)

    def select_source(self) -> None:
        src = self.source_var.get()
        if src == SOURCES[2]:
            self.choose_group_dir()
            return
        if src == SOURCES[3]:
            self.open_sequence()
            return
        self.refresh_groups(self.group_dir)
        if self.groups:
            self.select_group()
        else:
            self.status_var.set("该数据集在默认目录中没有序列")

    def refresh_groups(self, folder: Path = DEFAULT_GROUP_DIR) -> None:
        self.group_dir = folder
        self.groups = discover_test_groups(folder) if folder.exists() else {}
        fallback = ROOT / "artifacts/camus_unified_d_w4a8_board_20260905/demo"
        if not self.groups and folder == DEFAULT_GROUP_DIR and fallback.exists():
            self.groups = discover_test_groups(fallback)
        # The two built-in datasets share one folder: CAMUS at the top, TED below.
        src = self.source_var.get()
        if src in SOURCES[:2]:
            ted = src == SOURCES[1]
            self.groups = {k: v for k, v in self.groups.items() if k.startswith("TED") == ted}
            if ted:
                self.groups = {k.split("/", 1)[-1].strip(): v for k, v in self.groups.items()}
        self.group_box.configure(values=tuple(self.groups))
        if self.groups and self.group_var.get() not in self.groups:
            self.group_var.set(next(iter(self.groups)))

    def choose_group_dir(self) -> None:
        folder = filedialog.askdirectory(title="选择测试组目录 (*_2CH_*_image.npy / *_4CH_*_image.npy)")
        if folder:
            self.source_var.set(SOURCES[2])
            self.refresh_groups(Path(folder))
            if self.groups:
                self.select_group()
            else:
                self.status_var.set("目录中没有按 2CH/4CH 命名的图像序列")

    def select_group(self) -> None:
        views = self.groups.get(self.group_var.get(), {})
        if not views:
            return
        if self.view_var.get() not in views:
            self.view_var.set(next(iter(views)))
        self.view_box.configure(values=tuple(views))
        self.load_sequence(views[self.view_var.get()])

    def select_view(self) -> None:
        views = self.groups.get(self.group_var.get(), {})
        if self.view_var.get() in views:
            self.load_sequence(views[self.view_var.get()])
        else:
            known_view = self.sequence_metadata.get("view_id")
            if known_view in (2, 4):
                self.view_var.set(f"{known_view}CH")
                self.status_var.set("当前文件只有这个切面，请打开另一切面文件")
                return
            self.stop()
            self.selection_generation += 1
            self.seek_frame()

    def _scale_frame(self, value) -> None:
        self.frame_var.set(round(float(value)))

    def selected_index(self) -> int:
        try:
            value = self.frame_var.get()
        except tk.TclError:
            value = 1
        return min(max(value - 1, 0), max(len(self.frames) - 1, 0))

    def _update_rotation_label(self) -> None:
        self.rotation_var.set(f"旋转 {self.rotation_degrees}°")
        self.orient_var.set(f"{self.rotation_var.get()}  ·  {self.mirror_var.get()}")

    def _update_mirror_label(self) -> None:
        if self.mirror_x and self.mirror_y:
            text = "镜像：左右+上下"
        elif self.mirror_x:
            text = "镜像：左右"
        elif self.mirror_y:
            text = "镜像：上下"
        else:
            text = "镜像：无"
        self.mirror_var.set(text)
        self.orient_var.set(f"{self.rotation_var.get()}  ·  {text}")

    def _apply_rotation(self) -> None:
        k = (self.rotation_degrees // 90) % 4
        transformed = [np.rot90(frame, k=k) for frame in self.raw_frames]
        if self.mirror_x:
            transformed = [np.fliplr(frame) for frame in transformed]
        if self.mirror_y:
            transformed = [np.flipud(frame) for frame in transformed]
        self.frames = [np.ascontiguousarray(frame) for frame in transformed]
        self._update_rotation_label()
        self._update_mirror_label()

    def set_rotation(self, degrees: int) -> None:
        if not self.raw_frames:
            return
        self.stop()
        self.selection_generation += 1
        self.last_result = None
        self.rotation_degrees = degrees % 360
        self._apply_rotation()
        self.seek_frame()
        self.status_var.set(f"输入方向已设为 {self.rotation_degrees}°")

    def rotate_input(self, delta_degrees: int) -> None:
        self.set_rotation(self.rotation_degrees + delta_degrees)

    def toggle_mirror(self, axis: str) -> None:
        if axis not in ("x", "y"):
            raise ValueError(f"unsupported mirror axis: {axis}")
        self.stop()
        self.selection_generation += 1
        self.last_result = None
        if axis == "x":
            self.mirror_x = not self.mirror_x
        else:
            self.mirror_y = not self.mirror_y
        self._apply_rotation()
        self.seek_frame()
        self.status_var.set(f"{self.mirror_var.get()}，已应用到输入")

    def clear_mirror(self) -> None:
        if not self.mirror_x and not self.mirror_y:
            return
        self.stop()
        self.selection_generation += 1
        self.last_result = None
        self.mirror_x = self.mirror_y = False
        self._apply_rotation()
        self.seek_frame()
        self.status_var.set("镜像已恢复")

    def seek_frame(self) -> None:
        self.stop()
        self.selection_generation += 1
        self.last_result = None
        if not self.frames:
            return
        index = self.selected_index()
        self.frame_var.set(index + 1)
        self.frame_scale.set(index + 1)
        self._show(self.frames[index], None)
        self.input_title.set(f"{self.view_var.get()} · 第 {index + 1} 帧预览")
        self.output_title.set("尚未推理")

    def step_frame(self, delta: int) -> None:
        self.frame_var.set(self.selected_index() + 1 + delta)
        self.seek_frame()

    def save_result(self) -> None:
        if self.last_result is None:
            self.status_var.set("当前选择尚无推理结果")
            return
        selected = filedialog.asksaveasfilename(title="保存当前结果", defaultextension=".png",
                                                filetypes=(("PNG", "*.png"),))
        if selected:
            frame, mask, metadata = self.last_result
            path = Path(selected)
            Image.fromarray(make_overlay(frame, mask)).save(path)
            np.save(path.with_name(path.stem + "_mask.npy"), mask)
            Image.fromarray(frame).save(path.with_name(path.stem + "_input.png"))
            path.with_suffix(".json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            self.status_var.set(f"结果已保存：{path}")

    def open_sequence(self) -> None:
        selected = filedialog.askopenfilename(
            title="Open CAMUS sequence",
            filetypes=(
                ("CAMUS arrays", "*.npy *.npz *.nii *.nii.gz"),
                ("Images", "*.png *.jpg *.jpeg *.bmp *.tif *.tiff *.gif"),
                ("All files", "*.*"),
            ),
        )
        if not selected:
            return
        self.source_var.set(SOURCES[3])
        self.load_sequence(Path(selected))

    def load_sequence(self, path: Path) -> None:
        self.stop()
        try:
            frames = load_frames(path)
            metadata = load_sequence_metadata(path, len(frames))
            if not frames:
                raise ValueError("empty sequence")
            self.raw_frames, self.sequence_metadata = frames, metadata
            self._apply_rotation()
            self.sequence_path = path
            if self.sequence_metadata.get("view_id") in (2, 4):
                self.view_var.set(f"{self.sequence_metadata['view_id']}CH")
        except Exception as exc:
            self.status_var.set(f"载入失败：{exc}")
            return
        stype = metadata.get("sequence_type") or ("full_cycle" if "full_cycle" in path.name else
                                                 "half_sequence" if "half_sequence" in path.name else "")
        kind = {"full_cycle": "TED 完整周期", "half_sequence": "CAMUS 半周期"}.get(stype, "自选序列")
        self.path_var.set(f"{kind}  |  {path.name}  |  {len(self.frames)} 帧")
        for label, views in self.groups.items():
            if path.resolve() in {v.resolve() for v in views.values()}:
                self.group_var.set(label)
                self.view_box.configure(values=tuple(views))
                break
        else:
            self.group_var.set("自选序列")
            self.view_box.configure(values=("2CH", "4CH"))
        self.frame_spin.configure(to=len(self.frames))
        self.frame_scale.configure(to=max(1, len(self.frames)))
        self.frame_total_var.set(f"/ {len(self.frames)}")
        self.frame_var.set(1)
        self.seek_frame()
        self.status_var.set("序列已加载")

    def connect(self) -> None:
        if self.sock is not None:
            return
        try:
            sock = socket.create_connection((self.host_var.get(), self.port_var.get()), timeout=3.0)
            sock.settimeout(None)
        except OSError as exc:
            self.status_var.set(f"连接失败：{exc}（检查网线、IP 169.254.1.x、板卡服务）")
            return
        self.sock = sock
        self.stop_event.clear()
        threading.Thread(target=self._receive_loop, args=(sock,), daemon=True).start()
        self.status_var.set(f"已连接 {self.host_var.get()}:{self.port_var.get()}")
        self.conn_var.set("● 已连接")
        self.conn_label.configure(fg=OK)
        self.request_mode(self.mode_var.get())

    def disconnect(self) -> None:
        self.stop()
        sock, self.sock = self.sock, None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        with self.pending_lock:
            outstanding = len(self.pending)
            self.pending.clear()
        for _ in range(outstanding):
            try:
                self.window.release()
            except ValueError:
                break
        self.status_var.set("未连接")
        self.conn_var.set("○ 未连接")
        self.conn_label.configure(fg=MUTED)

    def start(self) -> None:
        self._launch(False)

    def test_once(self) -> None:
        self.stop()
        self.selection_generation += 1
        self._launch(True)

    def _launch(self, single: bool) -> None:
        self.shape_play.clear()
        if self.mode_var.get() != MODE_SEG:
            self.mode_var.set(MODE_SEG)
            self.select_mode(send=False)
        if self.sock is None:
            self.connect()
        if self.sock is None or not self.frames or self.play_event.is_set():
            return
        try:
            fps = min(max(float(self.fps_var.get()), 1.0), 60.0)
        except (ValueError, tk.TclError):
            self.status_var.set("FPS 必须是 1 到 60 的数值")
            return
        view_id = 2 if self.view_var.get() == "2CH" else 4
        loop = bool(self.loop_var.get())
        self.play_event.set()
        self.play_generation += 1
        self.selection_generation += 1
        self.last_result = None
        self.output_title.set("推理中")
        threading.Thread(
            target=self._send_loop,
            args=(fps, view_id, loop, self.play_generation, self.frames,
                  dict(self.sequence_metadata), self.sock, self.selected_index(),
                  single, bool(self.warmup_var.get()), self.selection_generation),
            daemon=True,
        ).start()

    def stop(self) -> None:
        self.play_generation += 1
        self.play_event.clear()

    def _send_loop(self, fps, view_id, loop, generation, frames, metadata, sock,
                   start_index=0, single=False, warmup=True, selection=0) -> None:
        indices = manual_frame_indices(start_index, warmup)
        index = indices[0] if single or warmup else start_index
        first = True
        deadline = time.perf_counter()
        metadata["sequence_id"] = time.monotonic_ns() & 0xFFFFFFFF
        while self.play_event.is_set() and self.sock is sock and generation == self.play_generation:
            frame = frames[index]
            self.window.acquire()
            if not self.play_event.is_set() or self.sock is not sock or generation != self.play_generation:
                self.window.release()
                break
            flags = FLAG_RESET_HISTORY if first else 0
            first = False
            if index == len(frames) - 1:
                flags |= FLAG_END_SEQUENCE
            metadata["frame_index"] = index
            try:
                # Prevent a newly selected sequence from interleaving TCP bytes
                # with a send that was already in progress when pause was pressed.
                with self.send_lock:
                    if generation != self.play_generation or self.sock is not sock:
                        self.window.release()
                        break
                    frame_id = self.next_frame_id
                    self.next_frame_id += 1
                    packet = build_frame_message(frame, frame_id, flags, view_id,
                                                  sequence_metadata=metadata)
                    with self.pending_lock:
                        self.pending[frame_id] = (time.perf_counter(), frame.copy(),
                                                  selection, index, view_id, index >= start_index)
                    sock.sendall(packet)
            except OSError as exc:
                with self.pending_lock:
                    self.pending.pop(frame_id, None)
                self.window.release()
                self.root.after(0, self.status_var.set, f"Send failed: {exc}")
                break
            self.tx_count += 1
            if single and index == start_index:
                if generation == self.play_generation:
                    self.play_event.clear()
                break
            index += 1
            if index >= len(frames):
                if loop:
                    index = 0
                    start_index = 0
                    first = True
                    metadata["sequence_id"] = (metadata["sequence_id"] + 1) & 0xFFFFFFFF
                else:
                    if generation == self.play_generation:
                        self.play_event.clear()
                    break
            deadline += 1.0 / fps
            delay = deadline - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            else:
                deadline = time.perf_counter()

    def _receive_loop(self, sock) -> None:
        try:
            while self.sock is sock:
                header = recv_exact(sock, HEADER.size)
                fields = HEADER.unpack(header)
                payload_len = fields[5]
                if fields[2] in (MSG_SHAPE_RESULT, MSG_STATUS):
                    expected = SHAPE_RESULT.size if fields[2] == MSG_SHAPE_RESULT else STATUS_RESULT.size
                    if payload_len != expected:
                        raise ValueError("unsupported shape/status payload size")
                    payload = recv_exact(sock, payload_len)
                    if zlib.crc32(payload) & 0xFFFFFFFF != fields[11]:
                        raise ValueError("shape/status CRC mismatch")
                    self.aux_queue.put((fields[2], fields[4], payload, time.perf_counter()))
                    continue
                if payload_len not in (RESULT_META.size + FRAME_BYTES,
                                       RESULT_META_V2.size + FRAME_BYTES):
                    raise ValueError("unsupported result payload size")
                payload = recv_exact(sock, payload_len)
                frame_id, mask, meta = parse_result_message(header, payload)
                with self.pending_lock:
                    sent = self.pending.pop(frame_id, None)
                if sent is None:
                    continue
                else:
                    host_ms = (time.perf_counter() - sent[0]) * 1000.0
                    frame = sent[1]
                self.window.release()
                self.rx_count += 1
                if sent[5]:
                    self.result_queue.put((frame_id, frame, mask, meta, host_ms,
                                           sent[2], sent[3], sent[4]))
        except (OSError, ConnectionError, ValueError) as exc:
            if self.sock is sock:
                self.root.after(0, self._connection_failed, sock, str(exc))

    def _connection_failed(self, sock, message) -> None:
        if self.sock is sock:
            self.disconnect()
            self.status_var.set(f"连接已断开：{message}")

    def _poll_results(self) -> None:
        latest = None
        try:
            while True:
                item = self.result_queue.get_nowait()
                if item[5] == self.selection_generation:
                    latest = item
        except queue.Empty:
            pass
        if latest is not None:
            frame_id, frame, mask, meta, host_ms, _, index, view = latest
            result_code, pl_status, _, hw_frame_id, accepted, completed, pack, encoder, decoder, service_us = meta[:10]
            self._show(frame, mask)
            self.input_title.set(f"{view}CH · 第 {index + 1} 帧 · 配对输入")
            self.output_title.set(f"{view}CH · 第 {index + 1} 帧 · PL 结果")
            self.frame_var.set(index + 1)
            self.frame_scale.set(index + 1)
            self.last_result = (frame, mask, dict(frame_id=frame_id, frame_index=index,
                                                 view_id=view, result_metadata=meta))
            with self.pending_lock:
                inflight = len(self.pending)
            self.status_var.set(
                f"Frame {frame_id} -> HW {hw_frame_id}  board {service_us / 1000:.2f} ms  host {host_ms:.2f} ms  status 0x{pl_status:08X}  rc {result_code}"
            )
            areas = meta[16:19] if len(meta) == 20 else tuple(
                np.count_nonzero(mask == c) for c in (1, 2, 3))
            provenance = "PL" if len(meta) == 20 else "Host"
            sequence_text = f"  Seq {meta[10]} {meta[11]+1}/{meta[12]}" if len(meta) == 20 else ""
            self.stats_var.set(
                f"TX {self.tx_count}  RX {self.rx_count}  In-flight {inflight}  "
                f"{provenance} pixels: LV {areas[0]} MYO {areas[1]} LA {areas[2]}"
                f"{sequence_text}"
            )
        self.root.after(10, self._poll_results)

    def _show(self, frame: np.ndarray, mask: np.ndarray | None) -> None:
        input_image = Image.fromarray(frame).resize((PREVIEW, PREVIEW), Image.Resampling.BILINEAR)
        overlay_image = Image.fromarray(make_overlay(frame, mask) if mask is not None else
                                        np.full((*frame.shape, 3), 16, dtype=np.uint8)).resize(
            (PREVIEW, PREVIEW), Image.Resampling.NEAREST
        )
        self.input_photo = ImageTk.PhotoImage(input_image)
        self.overlay_photo = ImageTk.PhotoImage(overlay_image)
        self.input_label.configure(image=self.input_photo)
        self.overlay_label.configure(image=self.overlay_photo)

    # ---- PYNQ-Z2 DFX: module selection and shape reconstruction ----------------
    def request_mode(self, mode: int) -> None:
        if self.sock is None:
            self.connect()
        if self.sock is None:
            return
        self.stop()
        self.shape_play.clear()
        header = HEADER.pack(MAGIC, VERSION_2, MSG_MODE, mode, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        with self.send_lock:
            try:
                self.sock.sendall(header)
            except OSError as exc:
                self.status_var.set(f"Send failed: {exc}")
                return
        self.pl_status_var.set("PL 模块：切换中…")

    def choose_shape_dir(self) -> None:
        folder = filedialog.askdirectory(title="选择形状病例目录 (inputs.bin / expected.bin / manifest.json)")
        if folder:
            self.load_shape_cases(Path(folder))

    def load_shape_cases(self, folder: Path) -> None:
        try:
            manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
            n = int(manifest["case_count"])
            self.shape_inputs = np.fromfile(folder / "inputs.bin", dtype=np.uint8).reshape(n, SHAPE_INPUT_BYTES)
            expected = folder / "expected.bin"
            self.shape_expected = (np.fromfile(expected, dtype=np.int8).reshape(n, 16)
                                   if expected.exists() else None)
            self.shape_labels = list(manifest.get("case_ids", []))
        except (OSError, ValueError, KeyError) as exc:
            self.shape_status_var.set(f"形状病例载入失败：{exc}")
            return
        self.shape_total_var.set(f"/ {n}")
        self.shape_source_var.set(f"{folder}  ·  {n} 例")
        self.shape_status_var.set(f"形状重建：已载入 {n} 个病例 ({folder.name})")
        if self.mode_var.get() == MODE_SHAPE:
            self._show_shape_input()

    def _send_shape(self, index: int) -> bool:
        if self.sock is None or self.shape_inputs is None:
            return False
        index %= len(self.shape_inputs)
        label = (self.shape_labels[index] if index < len(self.shape_labels) else f"case {index}").encode("utf-8")
        has_expected = self.shape_expected is not None
        expected = self.shape_expected[index] if has_expected else np.zeros(16, np.int8)
        meta = (struct.pack("!II", index, 1 if has_expected else 0) + expected.astype(np.int8).tobytes()
                + label[:32].ljust(32, b"\0") + bytes(8))
        payload = meta + self.shape_inputs[index].tobytes()
        with self.send_lock:
            frame_id = self.next_frame_id
            self.next_frame_id += 1
            header = HEADER.pack(MAGIC, VERSION_2, MSG_SHAPE, 0, frame_id, len(payload), 224, 224,
                                 FORMAT_SHAPE2, 0, 0, zlib.crc32(payload) & 0xFFFFFFFF,
                                 int(time.monotonic() * 1000) & 0xFFFFFFFF)
            self.shape_sent[frame_id] = time.perf_counter()
            try:
                self.sock.sendall(header + payload)
            except OSError as exc:
                self.root.after(0, self.shape_status_var.set, f"发送失败：{exc}")
                return False
        return True

    def _ensure_shape_mode(self) -> None:
        if self.mode_var.get() != MODE_SHAPE:
            self.mode_var.set(MODE_SHAPE)
            self.select_mode(send=False)

    def shape_once(self) -> None:
        self._ensure_shape_mode()
        if self.sock is None:
            self.connect()
        self.stop()
        self.shape_play.clear()
        self._show_shape_input()
        self._send_shape(max(self.shape_index_var.get() - 1, 0))

    def shape_start(self) -> None:
        self._ensure_shape_mode()
        if self.sock is None:
            self.connect()
        if self.sock is None or self.shape_inputs is None or self.shape_play.is_set():
            return
        self.stop()
        self.shape_play.set()

        try:
            period = min(max(float(self.shape_period_var.get()), 0.2), 10.0)
        except (ValueError, tk.TclError):
            period = 0.8

        def show(i: int) -> None:
            self.shape_index_var.set(i)
            self._show_shape_input()

        def loop(start: int) -> None:
            index = start
            while self.shape_play.is_set() and self._send_shape(index):
                self.root.after(0, show, index % len(self.shape_inputs) + 1)
                index += 1
                time.sleep(period)
            self.shape_play.clear()

        threading.Thread(target=loop, args=(max(self.shape_index_var.get() - 1, 0),), daemon=True).start()

    def _poll_aux(self) -> None:
        names = {MODE_SEG: "心腔分割 rm_seg", MODE_SHAPE: "形状重建 rm_shape"}
        try:
            while True:
                kind, frame_id, payload, arrived = self.aux_queue.get_nowait()
                if kind == MSG_STATUS:
                    code, mode, swaps, swap_us, _, _ = STATUS_RESULT.unpack(payload)
                    self.pl_status_var.set(f"PL 模块：{names.get(mode, '未知')}  (切换 {swaps} 次, 上次 {swap_us / 1000:.0f} ms)"
                                           + ("" if code == 0 else "  切换失败"))
                    continue
                values = SHAPE_RESULT.unpack(payload)
                code, case, checked, hw_us, service_us, recon_us = values[:6]
                codes = values[6:22]
                mismatches, mode, swaps, swap_us = values[22:26]
                sent = self.shape_sent.pop(frame_id, None)
                host_ms = (arrived - sent) * 1000 if sent else float("nan")
                label = self.shape_labels[case] if case < len(self.shape_labels) else f"case {case}"
                check = ("一致" if mismatches == 0 else f"{mismatches}/16 不一致") if checked else "未校验"
                self.shape_status_var.set(
                    f"形状重建 {label}：PL {hw_us / 1000:.2f} ms  板端 {service_us / 1000:.2f} ms  "
                    f"往返 {host_ms:.1f} ms  PCA {recon_us / 1000:.2f} ms  校验 {check}  "
                    f"系数 {' '.join(str(c) for c in codes)}" + ("" if code == 0 else "  PL 错误"))
                self.pl_status_var.set(f"PL 模块：{names.get(mode, '未知')}  (切换 {swaps} 次, 上次 {swap_us / 1000:.0f} ms)")
        except queue.Empty:
            pass
        self.root.after(20, self._poll_aux)

    def close(self) -> None:
        self.shape_play.clear()
        self.stop_event.set()
        self.disconnect()
        self.root.destroy()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="169.254.1.150")
    parser.add_argument("--port", type=int, default=5001)
    parser.add_argument("--sequence", type=Path)
    parser.add_argument("--autostart", action="store_true")
    parser.add_argument("--fps", type=float, default=30.0)
    parser.add_argument("--view", choices=("2CH", "4CH"), default="2CH")
    parser.add_argument("--rotate", type=int, choices=(0, 90, 180, 270), default=0,
                        help="rotate input frames counterclockwise by this angle")
    parser.add_argument("--mirror-x", action="store_true",
                        help="mirror input frames left-to-right")
    parser.add_argument("--mirror-y", action="store_true",
                        help="mirror input frames top-to-bottom")
    args = parser.parse_args()
    if sys.platform == "win32":
        # Without this Windows bitmap-stretches the window on >100 % displays (blurry text).
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass
    root = tk.Tk()
    global PREVIEW
    PREVIEW = int(PREVIEW * min(max(root.winfo_fpixels("1i") / 96.0, 1.0), 2.0))  # same size on HiDPI
    CamusStreamApp(
        root,
        args.host,
        args.port,
        sequence=args.sequence,
        autostart=args.autostart,
        fps=args.fps,
        view=args.view,
        rotation_degrees=args.rotate,
        mirror_x=args.mirror_x,
        mirror_y=args.mirror_y,
    )
    root.update_idletasks()
    w = min(max(root.winfo_reqwidth(), 1240), root.winfo_screenwidth() - 40)
    h = min(root.winfo_reqheight() + 10, root.winfo_screenheight() - 80)
    root.geometry(f"{w}x{h}+20+10")
    root.after(100, root.lift)
    root.after(120, root.focus_force)
    root.mainloop()


if __name__ == "__main__":
    main()
