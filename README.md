# 基于 PYNQ-Z2 的心脏外科超声评估与打结训练系统

心脏外科手术训练平台：心腔分割、三维形状重建、CAMUS 双平面 EF、心电（AD8232）、
JY62 姿态、两步结型识别、双手关键点、打结训练页。

## 目录

| 路径 | 内容 | 对应提交项 |
|---|---|---|
| `src/` | 全部源文件：PL（HLS 工程、DFX 构建、RTL）、PS C++、上位机、IP | 3.3.5.1 ① |
| `sim/` | 36 条 `profile_rtl` testbench + 3 条结型 SV 用例，含逐用例日志与复现脚本 | 3.3.5.1 ② |
| `build/` | DFX 构建脚本、综合与实现脚本、时序与资源报告 | 3.3.5.1 ③ |
| `board/` | 板上运行工程：`board_app/`（源码 + 已编译 `echo_demo` + 位流 + 模型）、`hand_pipeline_v3_20261010/`（手部后端运行时）、`deploy/`（systemd 单元）、`restore_board.sh` | 3.3.5.1 ④ |
| `data/` | 模型权重、心电录制、打结录像轨迹、分割对比基准 | 3.3.5.1 ④ |
| `host/` | 上位机 `camus_stream_host.py`、心电采集固件 `ecg_stream/ecg_stream.ino` | 3.3.5.1 ① |
| `skill/` | 技能包：各环节的适用范围 / 使用方法 / 失效条件 / 已验证效果 | 3.3.5.2 |
| `report/` | 交接文档、上板指南、设备连接图、界面截图、基准测试原始报告 | — |

路径命名只用小写 ASCII 字母、数字、`_`、`-`，全包可在 Linux / Windows / macOS 上直接解开。

---

## 一、动态部分重配置（DFX）

这是本作品的核心设计：单片 Zynq-7020 放不下四类加速器，用 DFX 让它们分时复用一个可重构分区。

### 1.1 为什么需要

| 配置 | LUT | BRAM | DSP |
|---|---|---|---|
| 四模块同时部署合计 | 155.5% | 186.4% | 156.8% |
| 分时部署后最大完整配置 | **64.0%** | **77.1%** | — |

四类模块同时部署的 LUT、BRAM、DSP 需求分别是全芯片的 155.5%、186.4%、156.8%，
物理上放不下。划分静态区 + 可重构分区后，最大完整配置降到 64.0% / 77.1%，四类任务
均可在单片器件上运行。

### 1.2 分区划分

```
xc7z020
├─ 静态区 shell（约 3.8 k LUT，DFX 期间不重配置）
│    HDMI 显示通路（VDMA + DVI 发送）、PS-PL AXI 互连、DFX 控制逻辑、
│    JY62 姿态接口、时钟（MMCM / BUFG / OSERDES）
└─ 可重构分区 rp_accel（U 形，覆盖 X1Y0-X1Y2 整列 + X0Y0）
     44,000 LUT / 120 RAMB36 / 180 DSP48
     ├─ rm_seg       心腔分割（W4A8）
     ├─ rm_shape     三维形状重建
     ├─ rm_cnn_top   结型识别
     └─ rm_cnn_top   手部关键点
```

静态区保留在 fabric 右侧 PS7 旁的窄条（2,400 slices / 20 RAMB36 / 40 DSP48），
加上 IO 与时钟列。可重构分区是两个满高度矩形，满足 `RESET_AFTER_RECONFIG` 的约束要求。
分区定义见 [`src/pl/rp_pblock.xdc`](src/pl/rp_pblock.xdc)、宽版 [`src/pl/rp_pblock_wide.xdc`](src/pl/rp_pblock_wide.xdc)：

```tcl
create_pblock pblock_rp_accel
resize_pblock pblock_rp_accel -add {SLICE_X50Y0:SLICE_X113Y149 ...}
resize_pblock pblock_rp_accel -add {SLICE_X0Y0:SLICE_X49Y49 ...}
add_cells_to_pblock pblock_rp_accel [get_cells shell_i/rp_accel]
set_property SNAPPING_MODE ON [get_pblocks pblock_rp_accel]
set_property RESET_AFTER_RECONFIG true [get_pblocks pblock_rp_accel]
```

### 1.3 统一接口

四个加速器内部结构不同，但对静态区暴露同一套接口：控制（AXI-Lite）、数据传输
（AXI-Stream / DataMover）、时钟、完成通知。接口一致性在生成位流前统一检查，
因此换模块只需重配置分区，静态区无需重配置。

RTL 实现：

| 文件 | 作用 |
|---|---|
| [`src/pl/rtl/dfx_ctrl_sync.v`](src/pl/rtl/dfx_ctrl_sync.v) | 跨重配置边界的控制信号同步 |
| [`src/pl/rtl/rp_ctrl_split.v`](src/pl/rtl/rp_ctrl_split.v) | 控制通路拆分（分区侧 / 静态侧） |
| [`src/pl/rtl/rp_mem_adapter.v`](src/pl/rtl/rp_mem_adapter.v) | 分区侧存储接口适配 |
| [`src/pl/hls/rm_cnn_top.v`](src/pl/hls/rm_cnn_top.v) | 结型 / 手部通用卷积核 wrapper |
| [`src/pl/sv_knot/rm_cnn_top.sv`](src/pl/sv_knot/rm_cnn_top.sv) | 结型识别分区顶层 |
| [`src/pl/sv_hand/rm_cnn_top.sv`](src/pl/sv_hand/rm_cnn_top.sv) | 手部关键点分区顶层 |

### 1.4 PS 侧切换流程

核心实现在 [`src/ps_app/hw.cpp`](src/ps_app/hw.cpp) 的 `DfxSlot::swap()`：

```
1. GPIO 拉低 SHUTDOWN  → 通知两个 shutdown manager 停止访问分区
2. 轮询 status 直到 0x3（隔离完成），超时 500 ms 则报错并放弃切换
3. GPIO 置 SHUTDOWN|HOLD → 保持复位，分区处于安全态
4. 写 /sys/class/fpga_manager/fpga0/firmware 加载 partial bin
   （flags=1 → FPGA_MGR_PARTIAL_RECONFIG）
5. 释放复位（仍隔离）→ 延时 1 ms
6. 完全解除隔离 → 延时 1 ms → 分区可用
```

任一步失败都保持分区隔离，绝不触碰分区内寄存器。

`fpga_load()` 加载前做 sync word 校验与字节换序：Vivado 生成的 bin 头部含
`AA 99 55 66`，驱动只认换序后的 `66 55 99 AA`，不换序会导致 partial load 失败。
加载后读 `fpga_manager/state`，不为 `operating` 即报错。

上层调度在 [`src/ps_app/worker.cpp`](src/ps_app/worker.cpp)：启动时把四个 partial bin
和当前 full bin 一并 stage 到 `/lib/firmware/`，切换页面时按需调用 `swap()`。
`worker.cpp:245` 在服务异常后强制清 mode，保证下一次请求一定会重新加载。

### 1.5 实测

| 项目 | 数值 |
|---|---|
| partial 重配置耗时 | 85–220 ms（另有 247.8 ms 的界面记录） |
| 切换期间 HDMI 显示 | 不中断（静态区三缓冲，重配置时隔离加速器与总线） |
| 切换期间计算任务 | 暂停，完成后恢复 |

### 1.6 构建

```bash
cd build/scripts
./dfx_all.sh                 # 一次跑完 shell + 四个 RM 的完整 DFX 流程
```

拆开看：

| 脚本 | 作用 |
|---|---|
| `bd_shell.tcl` | 静态外壳 block design（PS7、AXI 互连、VDMA、DVI、DFX GPIO） |
| `bd_rm_seg.tcl` / `bd_rm_shape.tcl` | 分割 / 三维形状分区的 block design |
| `create_dfx.tcl` | DFX 工程创建、分区与 pblock 绑定 |
| `build_dfx.tcl` | 综合、布局布线、partial bitstream 导出 |
| `rp_boundary.tcl` | 分区边界检查 |
| `build_incremental.sh` | 增量实现（改单个分区时省时） |

产物 7 个：3 个 full bin（`dfx_full_seg` / `dfx_full_knot_sv` / `dfx_full_hand_dual_roi_sv`）
和 4 个 partial bin（`dfx_partial_seg` / `dfx_partial_shape` / `dfx_partial_knot_sv` /
`dfx_partial_hand_dual_roi_sv`），已在 [`board/board_app/firmware/`](board/board_app/firmware/)。
静态外壳硬件描述在 [`board/bitstream/dfx_static.hwh`](board/bitstream/dfx_static.hwh)。

---

## 二、四类加速器

| 功能 | 源码 | 说明 |
|---|---|---|
| 心腔分割 `rm_seg` | [`src/pl/profile_rtl/`](src/pl/profile_rtl/)（117 个 `.sv`） | SE StreamSkipUNet，32,184 参数，每帧 149.7 M MAC，W4A8 |
| 三维形状重建 `rm_shape` | [`src/pl/hls/shape_v2/`](src/pl/hls/shape_v2/) | E-PiVox 形状参数推理 |
| 结型识别 `rm_cnn_top` | [`src/pl/hls/knot_dw3/`](src/pl/hls/knot_dw3/)、[`src/pl/sv_knot/`](src/pl/sv_knot/) | PL 检测 + PS 分类两步 |
| 手部关键点 `rm_cnn_top` | [`src/pl/sv_hand/`](src/pl/sv_hand/) | 双手 21 点 |

通用卷积核 [`src/pl/hls/cnn_engine.cpp`](src/pl/hls/cnn_engine.cpp) 为结型与手部共用，
L 形连续布局 + BRAM 参数存储 + 分组预取，把分区内占用率 ≥40% 的互连 Tile 从 56.4%
降到 34.8%，冲突线网从 1,962 条降到 0。

---

## 三、快速开始

### 3.1 跑仿真（对应 3.3.5.1 ②）

需要 Vivado Simulator 2024.2，默认装在 `~/Xilinx/Vivado/2024.2`（其他位置设 `VIVADO`）。

```bash
cd sim
./run/run_one.sh camus_pad2_stream_real_tb     # 单条
./run/run_all.sh 40                            # 全部 36 条，40 路并行，约 5 分钟
./run/knot_sim.sh                              # 结型 3 条
```

结果写入 `run/jobs/<tb>/{elaborate.log,console.log}`，通过的用例在 `console.log`
末尾打印 `PASS`。逐用例结果见 [`sim/README.md`](sim/README.md)：`profile_rtl` 36/36、
`knot` 3/3 全部通过。

### 3.2 恢复到板子（对应 3.3.5.1 ④）

前提：官方 PYNQ-Z2 v3.1 镜像，PC 网线直连，PC 以太网设 169.254.1.100/16。
包内已带编好的 `board/board_app/echo_demo`，不需要重新编译。

```bash
cd board
bash restore_board.sh 169.254.1.99
```

脚本把 `board_app/`、`hand_pipeline_v3_20261010/` 拷到 `/home/xilinx/`，装入 `deploy/` 下
`echo-demo.service` 与 `hand-sv.service`（含三个 drop-in），板上原有的同名目录先改名为
`*_before_restore_<时间戳>`，最后按「先 hand-sv，等 25 秒，再 echo-demo」的顺序启动。
逐步操作见 [`report/board_guide.md`](report/board_guide.md)。

从源码重编：

```bash
cd board/board_app
make -j2          # 源码在 ../../src/ps_app，产物 ./echo_demo
```

### 3.2.1 上位机与心电采集

```bash
python3 host/camus_stream_host.py --host 169.254.1.99
```

上位机只依赖 Python 3 标准库。心电：AD8232 → Arduino Uno（ATmega328P，CH340 USB 串口）
→ 板上 Python 读 `/dev/ttyUSB*`。固件源码 [`host/ecg_stream/ecg_stream.ino`](host/ecg_stream/ecg_stream.ino)，
Arduino IDE 选 Uno 板卡直接烧录。

### 3.3 上板自检

先把界面切到「① 心腔分割」页，再在 `~/board_app` 下运行：

```bash
python3 tools/proto_check.py
sudo python3 tools/ui_mouse_check.py
```

输出 `PROTO_CHECK_PASS` / `UI_MOUSE_CHECK_PASS`。

---

## 四、实测结果

### 4.1 分割：PL vs ARM 基线

| 实现 | 数据类型 | 单帧延迟 | 吞吐 | CAMUS val Dice |
|---|---|---|---|---|
| ARM A9 单线程 | float32 NEON -O3 | 890 ms | 1.12 fps | 0.8833 |
| ARM A9 双线程 | float32 | 549 ms | 1.82 fps | 0.8833 |
| ARM A9 双线程（手部服务同时运行） | float32 | 688 ms | 1.45 fps | 0.8833 |
| **PL rm_seg** | **W4A8** | **69 ms**（串行） | **28.7 fps**（流水） | **0.8835** |

加速比：延迟 8.0×，吞吐 15.8×。等效算力 PL 4.3 GMAC/s、CPU 0.27 GMAC/s。
W4A8 精度与 float32 持平（逐类 LV .923 / MYO .837 / LA .890），
22 帧 1,441,792 像素与 PyTorch 逐像素一致，logit 最大差 1.3e-5。

### 4.2 资源与时序

| 配置 | LUT | FF | BRAM（36K 当量） | DSP |
|---|---|---|---|---|
| 分割（整片） | 34,041 / 53,200（64.0%） | 35,588 / 106,400（33.4%） | 108 / 140（77.1%） | 115 / 220（52.3%） |
| 其中 rm_seg | 30,241 | 29,992 | 98 + 12×RAMB18 | 115 |
| 其中 rm_shape | 13,113 | 22,150 | 50 + 12×RAMB18 | 134 |

时序：WNS **+0.218 ns**，WHS **+0.019 ns**，0 失败端点。四种配置均完成布线。

### 4.3 结型识别

两步：PL 检测器在 320×256 全幅定位线结 → PS 分类器判单结 / 方结 / 三重结。

| 指标 | 数值 |
|---|---|
| 检测 AP50 | 99.3% |
| 分类准确率（5,371 张验证图像，5,226 张正确） | **97.30%** |
| 留一验证 | 97.9%（47/48） |
| 端到端帧率 | 约 4–5 fps（190–300 ms/帧） |

验证集按采集日期分组独立统计：10-02 94.2%、10-17 89.9%、10-19 98.7%、
10-27 100%、10-28 99.5%。`knot_cls_check` 在板上与训练端逐位一致（max diff 0）。

### 4.4 手部关键点

整体处理帧率 12.3 fps，自采打结视频验证集 PCK@0.1 = 95.9%，PCK@0.05 = 89.3%。

---

## 五、复现环境

| 用途 | 版本 / 依赖 |
|---|---|
| FPGA 综合、实现、仿真 | Vivado 2024.2（`~/Xilinx/Vivado/2024.2`，可用 `VIVADO` / `VIVADO_SETTINGS` 覆盖） |
| HLS | Vitis HLS 2024.2 |
| 板端系统 | PYNQ-Z2 v3.1 镜像（PYNQ 2.7，Ubuntu 22.04 armhf，内核 5.15） |
| 板端编译器 | `arm-linux-gnueabihf-g++` 11.4，`make -j2`，`-mcpu=cortex-a9 -mfpu=neon` |
| 板端 C++ 库 | `libxrt_coreutil`、`libfreetype6-dev`、`libpng-dev`、`libjpeg-dev`、`libpthread` |
| 手部后端运行时 | Python 3.10：`numpy`、`opencv-python`；`hand_pipeline_v3_20261010/lib{hand_board,hand_crop,hand_shared_bo}.so` 随包附带 |
| 训练 / 量化 | Python 3.11 + PyTorch（具体版本与命令行见 `skill/`） |
| 上位机 | Python 3，仅标准库 `socket` |
| 心电采集 | Arduino IDE 1.8+，Uno 板卡，固件 `host/ecg_stream/ecg_stream.ino` |

`build/scripts` 里的脚本默认以包根为工作区（`<pkg>/src` 取源码、`<pkg>/build/{ref,work,out}` 放中间产物），
不依赖固定的服务器目录。跑仿真前设 `PROFILE_RTL` 指向 `sim/profile_rtl_src`（`run_one.sh` 默认已这么找）。

## 六、文档

- [`report/handoff.md`](report/handoff.md) — 板上运行状态、改代码重编、结型重训流程
- [`report/board_guide.md`](report/board_guide.md) — 连板、重启服务、换模型、整版恢复
- [`report/benchmarks/RESULTS.md`](report/benchmarks/RESULTS.md) — 分割 PL/CPU 对比原始报告
- [`report/docs/device_wiring.png`](report/docs/device_wiring.png) — 设备连接图
- [`sim/README.md`](sim/README.md) — 逐用例仿真结果与复现方式
- [`skill/`](skill/) — 各环节技能说明
