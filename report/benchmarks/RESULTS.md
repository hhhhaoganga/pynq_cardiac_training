# 分割模型：PL 加速 vs ARM CPU 基线（2026-10-21 实测）

模型：SE StreamSkipUNet（通道 4-8-16-32，32,184 参数，每帧 149.7 M MAC，CAMUS 256×256，LV/MYO/LA）。
板卡：PYNQ-Z2（xc7z020，双核 Cortex-A9），位流与板上部署的 `dfx_full_seg.bin` / `dfx_partial_seg.bin` 逐字节一致。

## 1. 速度与精度

| 实现 | 数据类型 | 单帧延迟 | 吞吐 | CAMUS val Dice |
|---|---|---|---|---|
| ARM A9 单线程（服务停止） | float32，NEON，-O3 | 890 ms | 1.12 帧/秒 | 0.8833 |
| ARM A9 双线程（服务停止） | float32 | 549 ms | 1.82 帧/秒 | 0.8833 |
| ARM A9 双线程（手部服务同时运行） | float32 | 688 ms | 1.45 帧/秒 | 0.8833 |
| **PL rm_seg** | W4A8（权重 INT4 / 激活 INT8） | **69 ms**（串行） | **28.7 帧/秒**（流水） | **0.8835** |

- 加速比：延迟 8.0×（549 → 69 ms），吞吐 15.8×（1.82 → 28.7 帧/秒）。
- 等效算力：PL 4.3 GMAC/s；CPU 0.27 GMAC/s（双线程）。
- 精度：W4A8 QAT 0.8835，与 float32 0.8833 持平（逐类 LV .923 / MYO .837 / LA .890）。
- CPU 实现正确性：22 帧 1,441,792 像素与 PyTorch float 模型逐像素一致，logit 最大差 1.3e-5。
- CPU 实现：与 PL 同一流式调度（只编码新帧，复用前两帧 32×32 瓶颈）；1×1 投影放在上采样之前（等价，省 4× MAC），对 CPU 有利。
- CPU 分段（双线程空闲）：编码 178 ms、解码 365 ms、argmax 7 ms。
- PL 门禁 `proto_check.py`（板上运行，脚本在 `board/board_app/tools/proto_check.py`）：串行 / 流水各 8 帧 golden 0 失配，shape 150/150，PASS。
  第一次在 ④ 打结训练页上运行时 FAIL：该页持续请求手部模块，测试中 PL 被反复切换、清空了分割历史，换到分割页后通过。
  说明：上述两次运行的原始日志未随工程包提供，需要复现时按 `skill/phases/p5_board.md` 在板上重跑该脚本。

## 2. 资源占用（Vivado 2024.2，布线后，xc7z020）

| 配置 | 范围 | LUT | FF | BRAM（36K 当量） | DSP |
|---|---|---|---|---|---|
| 分割 | 整片 | 34,041 / 53,200（64.0%） | 35,588 / 106,400（33.4%） | 108 / 140（77.1%） | 115 / 220（52.3%） |
| 分割 | 其中 rm_seg（可重构区） | 30,241 | 29,992 | 98 + 12×RAMB18 | 115 |
| 三维形状 | 其中 rm_shape | 13,113 | 22,150 | 50 + 12×RAMB18 | 134 |

静态外壳（HDMI VDMA、DVI 发送、AXI 互连、中断、DFX GPIO 等）约 3.8 k LUT。时序：分割配置 WNS +0.218 ns，WHS +0.019 ns，0 失败端点。

## 3. 时钟域

| 时钟 | 频率 | 用途 |
|---|---|---|
| FCLK0 | 100 MHz | 控制 / AXI-Lite（ctrl_clk） |
| FCLK1 | 142.9 MHz | 静态外壳 |
| FCLK2 | 200 MHz | RP 计算（fast_clk） |
| clk_wiz_hdmi | 74.25 MHz | HDMI 720p60 像素时钟 |

## 4. 功耗估计（Vivado vectorless，置信度 Low，非实测）

| 项目 | 分割配置 | 三维配置 |
|---|---|---|
| 片上总功耗 | 2.055 W | — |
| 其中 PS7（双核 ARM + DDR 控制器） | 1.268 W | 1.268 W |
| 其中 RP 模块 | 0.340 W | 0.411 W |
| 静态功耗 | 0.165 W | 0.163 W |

- 板上没有电流传感器，以上为 Vivado 报告估计（默认翻转率 12.5%），不是测量值。
- 能效（按估计功耗）：PL 分割 28.7 帧/秒，RP 增量约 0.34 W；CPU 基线 1.82 帧/秒时 PL 空闲，整片功耗主要是 PS7 的 1.27 W。

## 5. DDR 带宽估计（未测量：静态外壳没有 AXI 性能监视器）

| 数据流 | 估计 |
|---|---|
| HDMI VDMA 读（XRGB8888 720p60，常驻） | 221 MB/s |
| 分割每帧 DDR 流量 | 1.18 MB（下界）~ 6.65 MB（上界） |
| 分割 @ 28.7 帧/秒 | 34 ~ 191 MB/s |
| HP 口峰值（64 bit） | 800 MB/s @100 MHz，1600 MB/s @200 MHz |

下界：输入帧 + 掩膜 + 跳连与瓶颈各写读一次 + 两帧历史瓶颈；上界：每层输出都写回 DDR 再读一次。权重在片上 ROM，不占 DDR。计算见 `ddr_estimate.py`。

## 文件

- `cpu/`：`seg_cpu.cpp`（CPU 基线源码）、`seg_float.bin`（float 权重）、`frames.u8` / `ref_masks.u8` / `ref_logits.f32`（测试帧与 PyTorch 参考）、`macs.json`、`board_cpu_run.log`（板上原始输出）
- `export_float.py`：从训练 checkpoint 导出权重和参考结果（服务器上运行）
- `vivado/`：利用率（整片 / 分层）、功耗（整片 / 分层）、时钟、时序报告，分割和三维两个配置
- `vivado_reports.tcl`：生成以上报告的脚本
- PL 门禁输出：未随包提供，见 `board/board_app/tools/proto_check.py`
- `ddr_estimate.py` / `ddr_estimate.json`：DDR 估计
- `results.json`：本表的机器可读版本
