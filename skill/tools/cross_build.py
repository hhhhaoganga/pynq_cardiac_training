"""Cross-compile board/*.c into ARM shared objects on the PC (never compile on the board).

  python skill/tools/cross_build.py [--out board_pkg] [--max-glibc 2.31]

Finds arm-linux-gnueabihf-gcc in $CROSS_CC, then the Vitis/Vivado install, then PATH.
After building, checks with readelf that the .so is 32-bit ARM hard-float and needs no
GLIBC symbol newer than --max-glibc (PYNQ 2.7 = Ubuntu 20.04 = 2.31, PYNQ 3.x = 2.35).
The Vitis 2024.2 sysroot ships glibc 2.39; without this check a .so can build fine and
then fail on the board with "version `GLIBC_2.3x' not found".
Exit 0 = CROSS_BUILD_PASS; exit 2 = no toolchain (driver falls back to pure Python).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
SOURCES = {"accel_native.c": "accel_native.so"}
CANDIDATES = [
    r"{root}\Vitis\{ver}\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin\arm-linux-gnueabihf-gcc.exe",
    r"{root}\Vitis_HLS\{ver}\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin\arm-linux-gnueabihf-gcc.exe",
    "{root}/Vitis/{ver}/gnu/aarch32/lin/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc",
]


def find_cc() -> str:
    if os.environ.get("CROSS_CC"):
        return os.environ["CROSS_CC"]
    roots = [os.environ.get("XILINX_ROOT", ""), r"C:\Xilinx", r"D:\Xilinx", "/tools/Xilinx", "/opt/Xilinx"]
    for root in filter(None, roots):
        for pat in CANDIDATES:
            hits = sorted(glob.glob(pat.format(root=root, ver="*")), reverse=True)  # newest version first
            if hits:
                return hits[0]
    for name in ("arm-linux-gnueabihf-gcc", "arm-linux-gnueabihf-gcc.exe"):
        if shutil.which(name):
            return shutil.which(name)
    return ""


def readelf_for(cc: str) -> str:
    cand = re.sub(r"gcc(\.exe)?$", r"readelf\1", cc)
    return cand if Path(cand).exists() or shutil.which(cand) else (shutil.which("readelf") or "")


def ver_tuple(v: str) -> tuple:
    return tuple(int(x) for x in v.split("."))


def check_so(readelf: str, so: Path, max_glibc: str) -> list:
    errs = []
    if not readelf:
        return ["找不到 readelf，无法检查架构和 glibc 版本"]
    hdr = subprocess.run([readelf, "-h", "-A", str(so)], capture_output=True, text=True).stdout
    if "ARM" not in hdr or "ELF32" not in hdr:
        errs.append(f"{so.name} 不是 32 位 ARM ELF（PYNQ-Z1/Z2/ZCU 的 Zynq-7000 是 armv7l）")
    if "Tag_ABI_VFP_args: VFP registers" not in hdr:
        errs.append(f"{so.name} 不是 hard-float（PYNQ 镜像是 armhf，要用 arm-linux-gnueabihf-gcc）")
    syms = subprocess.run([readelf, "-W", "--dyn-syms", str(so)], capture_output=True, text=True).stdout
    need = sorted({m for m in re.findall(r"GLIBC_(\d+\.\d+)", syms)}, key=ver_tuple)
    too_new = [v for v in need if ver_tuple(v) > ver_tuple(max_glibc)]
    if too_new:
        errs.append(f"{so.name} 需要 GLIBC_{too_new[-1]}，板上只有 {max_glibc}："
                    f"去掉新 libc 函数，或用 board.py doctor 查板上 glibc 后调 --max-glibc")
    print(f"{so.name}: GLIBC 需求 {need[-1] if need else '无'}（上限 {max_glibc}）")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path("board_pkg"))
    ap.add_argument("--max-glibc", default=os.environ.get("BOARD_GLIBC", "2.31"))
    a = ap.parse_args()
    cc = find_cc()
    if not cc:
        print("CROSS_BUILD_SKIP：没找到 arm-linux-gnueabihf-gcc（设 CROSS_CC，或装 Vitis 自带的 aarch32 工具链）；"
              "驱动会退回纯 Python MMIO，功能不变只是慢")
        return 2
    print(f"交叉编译器: {cc}")
    a.out.mkdir(parents=True, exist_ok=True)
    errs = []
    for src, so in SOURCES.items():
        dst = a.out / so
        # -mfloat-abi/-mfpu match the PYNQ armhf userland; no -march=native, the PC is not the target
        cmd = [cc, "-O2", "-shared", "-fPIC", "-Wall", "-Werror", "-mfloat-abi=hard", "-mfpu=neon",
               "-o", str(dst), str(SKILL / "board" / src)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            errs.append(f"编译 {src} 失败:\n{r.stdout}{r.stderr}")
            continue
        errs += check_so(readelf_for(cc), dst, a.max_glibc)
    if errs:
        print("\n".join(errs))
        print("CROSS_BUILD_FAIL")
        return 1
    print("CROSS_BUILD_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
