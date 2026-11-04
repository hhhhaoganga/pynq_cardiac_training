# pynq-flow 技能包

让大模型（包括能力较弱的模型）把一个 PYNQ 加速器工程从接口定义一路做到上板测速，而不会做到一半迷路。

出发点：弱模型写单个 HLS/Verilog 模块问题不大，难的是**编排**——知道现在处在哪一步、这一步什么算完成、失败了往哪查、上一轮做过什么决定。本技能包把这些从模型的"记忆和判断"里拿出来，交给文件和脚本：

- 状态机 `gate.py`：阶段状态存在 `skill_state.json`，换会话也能接着做。
- 机器判定的关卡：只有关卡命令退出码为 0 **且**输出 `GATE_PASS` 才进入下一阶段。
- 短卡片：每个阶段一张卡片，模型只读当前这张。
- 踩坑清单：失败日志自动匹配到相关条目；连续失败 2 次强制先查清单、记录假设。

与具体题目无关：不依赖本仓库的超声分割代码，任何 Zynq-7000 / Zynq UltraScale+ 的 PYNQ 板（PYNQ-Z1/Z2、ZCU104、KV260 等）都可以用。运行环境只有两处：**本地电脑**（Vivado/HLS、Python）和 **PYNQ Linux**（通过 ssh/scp）。

## 目录

| 路径 | 内容 |
|---|---|
| `SKILL.md` | 智能体入口：每轮先跑 `gate.py status`，6 条铁律，阶段表 |
| `phases/p0..p6_*.md` | 7 张阶段卡片：要做什么、关卡、不要做什么 |
| `pitfalls.md` | 踩坑清单，每条有关键词/现象/原因/确认/修复/来源 |
| `tools/gate.py` | 阶段状态机与关卡执行 |
| `tools/contract.py` | 接口契约的加载与校验（被其它工具共用） |
| `tools/gen_driver.py` | P0 关卡；生成板上包 `board_pkg/` |
| `tools/golden_compare.py` | P2/P5 关卡：按契约规则比对输出，并给出错误模式提示 |
| `tools/check_build.py` | P3 关卡：解析 Vivado 时序/资源报告，交叉检查 hwh |
| `templates/hls/`、`templates/hw/` | 向量加法（m_axi）的 HLS 内核/testbench/tcl；Vivado Block Design 构建脚本（PS7 + HLS IP）；PYNQ-Z2 PS7 预设 `ps7_pynq_z2.tcl`；干净环境启动脚本 `run_hls.bat` / `run_vivado.bat` |
| `templates/stream/` | AXI-Stream + AXI DMA 示例 `axis_scale`（y = x·k + b）：契约、黄金模型、HLS 内核/testbench、带 AXI DMA 的构建脚本、真板报告 |
| `tools/board.py` | PC → 板卡：doctor / push / smoke / test / run，全部带超时 |
| `tools/perf_report.py` | P6 关卡：只用实测数据生成性能报告 |
| `board/accel_driver.py` | 通用板上驱动：完全由 `contract.json` 驱动，所有等待都有截止时间 |
| `board/board_smoke.py` | P4 板上冒烟：按步骤检查，失败时指出是哪一步 |
| `board/board_test.py` | P5/P6 板上运行：输出 + 分段计时 + ARM CPU 基线 |
| `board/fake_pynq.py` | 无板调试：用黄金模型模拟 PL |
| `board/accel_native.c` + `tools/cross_build.py` | 驱动的 C 快速路径（DMA 挂起/ap_start/轮询），在 PC 上用 Vitis 自带的 arm-linux-gnueabihf-gcc 交叉编译成 `accel_native.so`，板上不编译 |
| `templates/` | `contract.yaml` 与 `golden/{model,selftest}.py` 示例（向量加法；流式示例在 `templates/stream/`） |

## 各组成部分

### 1. 阶段状态机 `gate.py` + `SKILL.md`
- 适用范围：任何"多步骤、每步都能用脚本判定"的 FPGA 工程流程。阶段与关卡命令可以用 `gate.py set-gate` 替换。
- 使用方法：`gate.py init --board xilinx@<ip>`，之后每轮 `gate.py status` → 读卡片 → 做事 → `gate.py run`。决定用 `note`，假设用 `issue`/`resolve`，回退用 `back`。
- 失效条件：模型不遵守"每轮先 status"的约定，或者绕过 `gate.py` 直接手动判断完成；关卡命令本身写错（总是 PASS）时状态机无法发现。
- 已验证效果：向量加法示例在真板 PYNQ-Z2 上 P0→P6 全部 GATE_PASS（本地 Vitis HLS/Vivado 2024.2 构建，WNS 1.354 ns，报告见 `templates/vadd_pynq_z2_perf.md`）；AXI-Stream + AXI DMA 示例 `axis_scale` 同样在真板上 P0→P6 全部 GATE_PASS（WNS 0.967 ns，报告见 `templates/stream/axis_scale_pynq_z2_perf.md`）；两个示例也都在 `--board fake` 下跑到 P5；P6 正确拒绝 fake 数据；连续失败 2 次时输出强制提示；每次失败的完整日志保存在 `skill_logs/`。
- 来源：本项目前期没有阶段划分，多次出现"黄金比对通过就以为完成"、跨会话丢失决策（参见 `docs/claude/memory/`）。

### 2. 接口契约 `contract.yaml` + `gen_driver.py --check`
- 适用范围：PS 通过 AXI-Lite 控制、数据走 m_axi 或 AXI DMA 的加速器；HLS（`ap_ctrl_hs`）或无启动位的流式 IP。
- 使用方法：从 `templates/contract.yaml` 复制并修改；寄存器偏移照抄 HLS 生成的 `x*_hw.h`。
- 失效条件：使用中断驱动、`ap_ctrl_chain` 连续流水、多个协同 IP 或 VDMA 视频流时，需要扩展驱动；契约只描述单个 IP。
- 已验证效果：m_axi（vadd）与 AXI DMA 流（axis_scale，`streams` + 标量寄存器）两种接口都在真板上验证。能检查重名、未对齐、与 HLS 控制区重叠、寄存器互相重叠、引用不存在的缓冲区、标量越界、输出缺少比对规则、DMA 方向错误。
- 来源：通用经验（寄存器偏移手抄错误是上板失败最常见的原因之一）。

### 3. 通用板上驱动 `accel_driver.py`
- 适用范围：PYNQ 2.x / 3.x，Zynq-7000 与 ZU+。
- 使用方法：`board.py push/smoke/test` 会自动打包；也可以在自己的应用里 `Accel("contract.json")(inputs)`。
- 失效条件：同上（中断、chain、多 IP）；PYNQ API 发生不兼容变化时需要调整。
- 已验证效果：fake 模式下验证了寄存器编程（64 位地址先低后高）、flush/invalidate、截止时间超时（`PYNQ_FAKE_HANG=1` 时 2 s 内抛出 TimeoutError 并打印寄存器）、漏掉 flush 时报错。真板（PYNQ-Z2，pynq 3.1.1）上向量加法 1024 点逐项一致，内核运行 0.127 ms，端到端 1.067 ms（20 次平均）；AXI DMA 流（先挂 S2MM 再发 MM2S，再写 ap_start，按 DMASR 等待）1024 点逐项一致，内核+DMA 0.710 ms，端到端 1.330 ms。
- 来源：实测（本项目的 AXI 挂死冻结整板，所以所有等待都带截止时间，风险步骤前先 `os.sync()`）。

### 4. 板卡桥 `board.py`
- 适用范围：PC 有 OpenSSH 客户端（Windows 10+ 自带），板卡运行 PYNQ Linux。
- 使用方法：一次性 `ssh-copy-id xilinx@<ip>`；sudo 需要密码时设置 `PYNQ_SUDO_PASS`。然后 `board.py doctor`。
- 失效条件：板卡不在 ssh 可达的网络上；镜像不是 PYNQ（找不到 `/etc/profile.d/pynq_venv.sh` 时会跳过，但 `import pynq` 会失败）。
- 已验证效果：fake 模式完整流程；ssh 参数（BatchMode、ConnectTimeout、ServerAlive）和"只用相对路径传给 scp"的做法来自本项目实测。真板 PYNQ-Z2 上 doctor/push/smoke/test 全部跑通（密钥用 `PYNQ_SSH_KEY`，sudo 密码用 `PYNQ_SUDO_PASS`）。
- 来源：实测（ssh 写 FIFO 永久阻塞、Windows/MSYS 下 scp 路径被改写、sudo 与 PYNQ 环境脚本）。

### 5. 关卡工具 `golden_compare.py` / `check_build.py` / `perf_report.py`
- 适用范围：输出为 numpy 可读的数组（`.npy` 或原始小端 `.bin`）；Vivado 2019.x 及以后的 `report_timing_summary` / `report_utilization` 文本格式。
- 失效条件：输出是变长或结构化数据（需要自己写比对）；报告格式被自定义；不止一个 `.bit`。
- 已验证效果：`check_build.py` 用本仓库真实的 Vivado 2024.2 报告解析出 WNS 0.340 / WHS 0.009 / LUT 70% / BRAM 78.57% / DSP 52.27%；能拒绝资源超限、hwh 中不存在的实例、不在 hwh 寄存器表中的偏移。`golden_compare.py` 对全错、从某处起全错、数值相同位置不同三种模式给出提示。
- 来源：实测（本项目时序/资源门槛）+ 通用。

### 6. 踩坑清单 `pitfalls.md`
- 适用范围：PYNQ + Vivado/HLS 工程。每条都标注了「实测」或「通用」。
- 使用方法：`gate.py run` 失败时自动按关键词列出相关条目；连续失败 2 次必须先读。
- 失效条件：关键词匹配是简单的子串匹配，新的错误文本可能匹配不到，需要人工浏览。
- 已验证效果：「实测」条目都是本项目开发中真实遇到并修复的问题（方向错误导致的黄金假通过、部分比特流字节序、AXI 挂死、FIFO 阻塞、PL 瓶颈等）。
- 来源：本项目开发记录 `docs/claude/memory/*.md` 与会话导出。

### 7. 无板调试 `fake_pynq.py`
- 适用范围：还没有比特流或板卡不在手边时，验证驱动和测试脚本。
- 失效条件：不能发现时序、缓存一致性、总线、DMA 硬件行为的问题。P6 会拒绝 fake 数据，防止拿模拟数字写报告。
- 已验证效果：向量加法（m_axi）与 axis_scale（AXI DMA 流 + ap_ctrl_hs）示例的 P4/P5 在 fake 模式和真板 PYNQ-Z2 上都通过。

### 8. 交叉编译的驱动快速路径 `accel_native.c` + `cross_build.py`
- 适用范围：Zynq-7000（armv7 硬浮点，PYNQ-Z1/Z2 等）上的 PYNQ Linux；PC 上装有 Vitis/Vitis HLS（自带 `gnu/aarch32/.../arm-linux-gnueabihf-gcc`），或用 `CROSS_CC` 指定其它交叉编译器。ZU+（aarch64）需要换编译器和 `-m` 参数。
- 使用方法：不用手动调用。`board.py push/smoke/test` 打包时自动运行 `cross_build.py`，把 `accel_native.so` 放进 `board_pkg/`；驱动启动时用 ctypes 加载，`board_test.py` 的 `timing.json` 和 P6 报告里写明 `驱动: native|python`。对照测试：`PYNQ_NATIVE=0` 强制走纯 Python。单独检查：`python skill/tools/cross_build.py --max-glibc <板上 ldd --version 的版本>`（`board.py doctor` 会打印板上 glibc）。
- 失效条件：PC 上找不到交叉编译器（退出码 2，自动回退纯 Python，功能不受影响，只是慢）；编译器的 glibc 比板上新且用到了新符号（`cross_build.py` 用 readelf 检查 GLIBC 版本，超过就 FAIL）；板子是软浮点镜像；fake 模式下不使用。缓冲区的 flush/invalidate 仍由 PYNQ 完成，C 路径只替换寄存器访问序列。
- 已验证效果：Vitis 2024.2 自带 GCC 13.3（sysroot glibc 2.39）编出的 `.so` 只依赖 GLIBC_2.17 符号，可在 PYNQ-Z2（glibc 2.35）上加载；readelf 检查 ELF32 ARM + VFP 硬浮点通过；fake 模式回归通过（自动回退 python）。真板（axis_scale 流式例子，1024×int32，50 次平均）：`run()` python 0.723 ms → native 0.080 ms（9x），端到端 1.207 ms → 0.675 ms，输出与黄金逐位一致。Python 路径下 `sendchannel.transfer()` 已经 flush 发送缓冲，驱动不再重复 flush。
- 来源：实测（弱模型 A/B 实验中 relu_q 的剖析：纯 Python MMIO 每次读约 15 us、写约 17.5 us，一次 DMA 调用的寄存器序列占端到端大头，加速比只有 1.04x）；板上 gcc 编译慢且依赖板上环境，所以统一在 PC 交叉编译。

## 快速开始（向量加法示例）

```bash
mkdir D:/work/vadd && cd D:/work/vadd      # 路径只用 ASCII
cp -r <本仓库>/skill .
cp skill/templates/contract.yaml .
mkdir golden && cp skill/templates/golden/*.py golden/
python skill/tools/gate.py init --board xilinx@192.168.2.99
python skill/tools/gate.py run              # P0
python skill/tools/gate.py run              # P1，生成 data/golden/
# P2/P3 在本地 Vivado/HLS 完成后：
python skill/tools/gate.py run
```

流式（AXI DMA）示例：把上面的 `templates/contract.yaml` 换成 `templates/stream/contract.yaml`，`golden/model.py` 换成 `templates/stream/golden/model.py`，HLS 源文件用 `templates/stream/hls/`，构建脚本用 `templates/stream/hw/build_overlay.tcl`（`ps7_pynq_z2.tcl`、`run_*.bat` 与向量加法共用）。

依赖：PC 上 Python 3.8+、numpy、pyyaml、OpenSSH；板上 PYNQ 镜像自带的 numpy 与 pynq。
