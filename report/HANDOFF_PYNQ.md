# PYNQ-Z2 心脏超声 DFX 演示：交接文档

2026-10-08 更新：已集成并上板验证 SV 结型 DW3/E3 256×320 核；当前服务默认启动摄像头结型检测，支持切回原分割/三维。实板22块对拍与原协议回归通过，端到端20fps尚未达到。当前部署与操作以 [结型实板记录](pynq_dfx/sv_knot/BOARD_DEPLOY_20261008.md) 为准，以下早期描述保留作背景。

快照：2026-09-30，2026-10-02 补充 JY62 姿态跟随（§5）、USB 摄像头页（§5）、增量构建（§6）。
当前板上运行的就是本仓库的代码与 `pynq_dfx/board_dfx` 固件。
旧的 FreeRTOS 版本见 `HANDOFF.md`（已废弃，仅供查历史）。

## 1. 系统概览

- 板卡 PYNQ-Z2（xc7z020clg400-1），SD 启动官方 PYNQ v3.1.1 镜像（Ubuntu 22.04，CMA 128 MB）。
- PL = 静态 shell + 一个 DFX 可重构分区（RP），分时加载两个模块：
  - **rm_seg**：SE U-Net W4A8，CAMUS 分割 LV/MYO/LA，256×256，约 30 fps（PL 解码器瓶颈）。
  - **rm_shape**：E-PiVox K16 三维形状重建（HLS `shape_top` 2.0），约 3.5 ms/例。
  - 切换走 `/sys/class/fpga_manager`，约 85–106 ms，HDMI 不断。
- 静态部分：PS7、HDMI 720p60（VDMA XRGB8888 三缓冲 @0x4300_0000 + 固定时序 `rtl/vtg_720p.v`）、
  axi_intc @0x4180_0000、dfx_gpio @0x4120_0000（ch1 bit0 shutdown 请求，bit1 RP 复位保持；ch2 状态）。
- RP 边界（冻结，勿改）：S_AXI_CTRL AXI-Lite 8 bit @0x4000_0000；M_AXI_MEM AXI4 64b ID6 → HP2；
  ctrl_clk 100 MHz + fast_clk 200 MHz；irq → intc[0]。
  rm_shape 内部用 `rtl/rp_ctrl_split.v` 把 256 B 拆成 DMA（0x00–0x7F）和 shape_top（0x80–0xFF）。
- 板端程序 `pynq_dfx/board_app`（C++17，不依赖 pynq）：
  - 自己加载 `firmware/dfx_full_seg.bin`，partial 做 32 bit 字节交换后写 fpga_manager。
  - 线程：net（TCP 5001，CMS1 协议）/ worker（唯一访问 RP 的线程）/ UI（30 fps，HDMI + USB 鼠标）/ demo（无上位机 20 s 后本地循环）。
  - 三维：PCA 64³ SDF 重建 → surface nets 网格 → 整数光栅化。
- 上位机 `host/camus_stream_host.py`（Tkinter），发送帧或 shape 用例，协议见 `board_app/src/proto.hpp`。

## 2. 目录

| 路径 | 内容 |
| --- | --- |
| `pynq_dfx/scripts/` | Vivado 构建脚本（服务器上跑），`serial_cmd.ps1`、`flash_sd.ps1` |
| `pynq_dfx/rtl/`、`rtl_override/`、`constraints/`、`tb/` | shell/RP 自写 RTL、覆盖原始 RTL 的修正版、pblock 约束、TB |
| `pynq_dfx/hls_shape_v2/` | shape_top 2.0 HLS 源码 + `verify_export.sh`（csim→csynth→cosim→export） |
| `pynq_dfx/board_dfx/` | **当前固件**（DFX full/partial）+ 上板检查 `check_dfx.py` |
| `pynq_dfx/board/`、`board_shape/` | 阶段 1/2 的 flat 位流及检查脚本（历史，可作对照） |
| `pynq_dfx/board_app/` | 板端 C++ 程序：`src/`、`tools/`（门禁测试）、`data/`（演示序列、shape 模型）、`deploy/`、`fonts/` |
| `host/` | PC 上位机；`host/data/` 是演示数据（`camus_demo_groups` 与其重复） |
| `build_inputs/src/` | 服务器构建所需外部源码：profile_rtl、pl_rom_se_candidate、ip_repo*、shape fixtures |
| `build_inputs/ref/ps7_block.tcl` | 官方 PYNQ-Z2 PS7 预设 |
| `software_reference/` | 服务器 QAT 训练脚本参考 |
| `docs/claude/` | 上一位开发者的 Claude Code 对话导出和记忆笔记（见第 9 节） |

不在 git 里（体积大或可再生，仍在原 PC 上）：`vivado_vitis/`、`bit/`、`elf/`（FreeRTOS 旧工程）、
`handoff/epivox_k16/`（shape 原始交付包，300 MB）、服务器上的 `work/ out/ logs/`。
`build_inputs/ref/PYNQ` 未入库：是 https://github.com/Xilinx/PYNQ.git 的 `19ed17d`，需要时自行 clone。

## 3. 连接开发板

- 网线直连 PC。板子地址 169.254.1.99（ssh）/ 169.254.1.150（上位机）/ 192.168.2.99。
  `echo-demo.service` 启动时会自动加上两个 169.254 地址。
- 登录：`ssh xilinx@169.254.1.99`，密码 `xilinx`（sudo 同密码）。原开发机用密钥 `~/.ssh/pynq_board_ed25519`。
- 网络不通时走串口（COM6，自动登录）：`pynq_dfx/scripts/serial_cmd.ps1 -Cmd 'sudo ip addr add 169.254.1.99/16 dev eth0'`。
- PC 网卡需在 169.254.0.0/16 网段，防火墙放行 Python。

## 4. 板端程序：修改、编译、部署

板上目录 `/home/xilinx/board_app/`，结构与 `pynq_dfx/board_app/` 相同，另有 `firmware/`
（= `board_dfx/dfx_full_seg.bin`、`dfx_partial_seg.bin`、`dfx_partial_shape.bin`）。

```bash
scp -r pynq_dfx/board_app/src xilinx@169.254.1.99:/home/xilinx/board_app/
ssh xilinx@169.254.1.99 "cd board_app && make -j2 && sudo systemctl restart echo-demo"
```

- 首次在新板上：把整个 `board_app/` 和 `firmware/` 拷过去，`sudo bash deploy/install.sh`（编译 + 安装开机服务）。
  在 PC 上一条命令完成：`bash pynq_dfx/board_app/deploy/deploy_board.sh [板子IP]`（Git Bash，会问几次密码 xilinx）。
- 从 Windows 拷 `.sh` 后先 `sed -i 's/\r$//' xxx.sh`。
- 日志：`journalctl -u echo-demo -f`；截图：`sudo sh -c 'echo /tmp/x.png > /tmp/echo_demo_shot'`；
  90 帧 UI 性能剖析：`sudo touch /tmp/echo_demo_profile` 后看日志。

**每次改完必须在板上跑三道门禁**（都在 `board_app/` 下）：

| 命令 | 通过标志 | 覆盖内容 |
| --- | --- | --- |
| `python3 tools/proto_check.py` | `PROTO_CHECK_PASS` | seg golden 0 mismatch（串行+流水）、shape 150/150、模块切换、fps |
| `sudo python3 tools/ui_mouse_check.py` | `UI_MOUSE_CHECK_PASS` | 鼠标点击各页面/按钮、双平面 EF 与 Python 对照、截图 |
| `sudo sh tools/demo_toggle_check.sh` | `DEMO_TOGGLE_PASS` | 本地演示开关 |

## 5. UI 功能（HDMI + USB 鼠标）

- 顶部页签：分割 / 三维重建（点页签会切 PL 模块）/ 摄像头（只换屏幕，不切 PL）。
- 分割页右上：`双切面`（A2C+A4C，CAMUS 数据）/ `仅 A4C`（长序列布局，播 TED 全周期）。
- 底部右侧：`本地演示：开/关`。关掉后板子只等上位机。
- 本地演示序列：`data/demo/seqs.txt`（双切面）和 `seqs_a4c.txt`（4 段 TED A4C，第 6 列是循环次数）。
  格式 `<file.npy> <view> <study> <sx_nm> <sy_nm> [loops]`。演示按 33.3 ms 截止时间节拍送帧。
- 三维页：模型自动旋转，鼠标拖动时暂停自动旋转并跟随拖动。
- JY62 姿态跟随（`src/imu.cpp`）：JY62 接 Pmod JB（pin1=W14=UART1 RX ← JY62 TX，pin2=Y14=UART1 TX → JY62 RX，
  pin5 GND，pin6 3V3）。在线时三维模型跟随 IMU 姿态转动、自动旋转冻结，三维视图右上角显示横滚/俯仰/航向；
  右键同时复位视角并把当前姿态记为零点（只取航向作参考）。yaw 会漂，漂了就右键重新归零。
  超过 500 ms 没包判离线，退回自动旋转。没有 `/dev/ttyPS1` 时 app 自己经 `/dev/mem` 打开 UART1 时钟并配寄存器
  （日志 `main: JY62 on ...`）；115200 收不到包 1.5 s 后试 9600。`--no-imu` 关掉。
- `③ 摄像头` 页（`src/camera.cpp`）：USB UVC 摄像头（可经 USB 扩展坞，和鼠标同时用），V4L2 mmap 采 MJPEG，
  PS 端 libjpeg-turbo 解成 XRGB 直接显示。默认 640×480，30 帧/秒，解码约 24 ms/帧；720p 实测只有约 15 帧/秒
  （解码 66 ms），所以不用。`--camera-size WxH` 改分辨率，`--no-camera` 关掉。热插拔自动重连，离开此页时不解码。
  本页只是显示，不占 PL，后台演示照常轮换 seg/shape。
- **供电**：扩展坞 + 摄像头 + 鼠标时 USB 供电带不动（上电到 `hub found` 就复位重启），必须 DC IN 接 7–15V
  （内正外负 5.5×2.1，用 12V/3S 锂电），电源跳线拨到 REG。Micro-USB 仍可同时接着用 JTAG/串口。

## 6. FPGA 构建（服务器 hlab，Vivado 2024.2）

本机性能弱，**不要在 PC 上综合**。服务器目录布局：

```
/home/lizx/pynq_dfx_20260929/
  pynq_dfx/   ← 本仓库 pynq_dfx/
  src/        ← 本仓库 build_inputs/src/
  ref/        ← build_inputs/ref/ + git clone PYNQ 到 ref/PYNQ（19ed17d）
  work/ out/ logs/   （生成）
```

- 上传后 `sed -i 's/\r$//' pynq_dfx/scripts/*.sh pynq_dfx/scripts/*.tcl`。
- DFX 全流程：`./pynq_dfx/scripts/dfx_all.sh wide`（当前固件用 wide pblock，`constraints/rp_pblock_wide.xdc`），
  产物 `out/shell_dfx_wide/dfx_full_*.bit/bin`、`dfx_partial_*.bin`、`pr_verify.rpt`。脚本需要 `~/Xilinx/Vivado/2024.2/settings64.sh`。
- 单模块 flat 构建：`run_vivado.sh create_project.tcl <log> rm_seg|rm_shape` → `sweep_impl.tcl`（多策略扫时序）。
- shape HLS：`pynq_dfx/hls_shape_v2/verify_export.sh` → `src/ip_repo_shape_v2`。
- 当前固件（2026-10-02，静态加 UART1 EMIO）：seg WNS +0.218 / WHS +0.019，shape WNS +0.187 / WHS +0.014，
  DRC 0，pr_verify 兼容。服务器目录 `/home/lizx/pynq_dfx_jy62_20260930`，产物 `out/shell_dfx_wide_pr`。
  旧固件备份在 `board_dfx/bak_pre_jy62_20261002/`。
- **静态 shell 有小改动时用增量实现**：普通全量实现会让 seg 重新布局、布线拥塞失败（试过 3 种策略都 route 不通）。
  做法：`create_dfx.tcl wide <策略> <tag>` 建工程后，
  `run_vivado.sh set_incremental.tcl <log> wide_<tag> <参考工程>/shell_dfx.runs physopt` 让 impl_1 参考上一版通过的
  routed dcp（复用 99.99%），再 `build_dfx.tcl wide_<tag>`。全程约 15 分钟。
  一条命令版：`bash pynq_dfx/scripts/build_incremental.sh <tag>`（参考 dcp 放在 `pynq_dfx/ref_dcp/impl_1/`）。参考 dcp 目前在
  `/home/lizx/pynq_dfx_20260929/work/shell_dfx_wide/` 和 `pynq_dfx_jy62_20260930/work/shell_dfx_wide_pr/`。

## 7. 性能与模型现状

- seg：稳定 30.1 fps（仅 A4C 连续序列），延迟约 73 ms；PL 各段 pack 1.4 / enc 30 / dec 32 / post 6 ms。
  **瓶颈在 PL 解码器**，调 PS 端没用。旧 FreeRTOS 版约 24 fps。
- UI 分割页每帧约 26 ms（绘制 17 + cache flush 8）。
- shape：PL 3.5 ms；PS 端 SDF 重建 55–63 ms、网格 35 ms、光栅化 34 ms。
- seg 模型 CAMUS val Dice 0.884（LV .923 / MYO .837 / LA .891），多种改法都停在 0.88 左右；pblock 已占 95% slice，没有余量。
- shape 模型输入是合成网格的二值心壁切片，目标是全心包络 SDF，所以**不能把 CAMUS 分割结果直接接给 shape**。
  要串联需要重做 shape 训练数据（CAMUS 风格 LV/MYO/LA 掩码、LV 腔 SDF 目标、加分割噪声增强），只重建 rm_shape。

## 8. 踩过的坑（务必先看）

1. **分割结果像噪声 = 方向问题，不是硬件问题。** 模型训练用的是转置后的心尖朝上图像，
   `board_app/src/accel.cpp` 输入输出都做转置。`se_golden_8` 本身是训练方向，golden 通过不代表方向对。
2. **RM 的问题不要动静态 shell / RP 边界。** 任何静态网表变化都会让 seg 重新布局并布线拥塞（WNS −0.7）。
   S_AXI_CTRL 保持 8 bit，新 RM 的寄存器塞进 256 B（用 `rp_ctrl_split.v`）。
3. partial `.bin` 写 fpga_manager 前要 32 bit 字节交换，否则被**静默忽略**。
4. pynq `Overlay()` 解析不了这些 hwh，板端程序不依赖 pynq；Python 检查脚本用 `Bitstream().download()` 兜底。
5. 通过 ssh 写 `/tmp/echo_demo_input`（FIFO）可能永久阻塞：一律 `timeout 2 sh -c 'echo ... > /tmp/echo_demo_input'`。
6. 服务器上 ssh 里 `pkill -f` 会杀掉自己的 shell，按 PID 杀。
7. 三维深度：深度缩放必须按当前网格实际范围（`render3d.cpp` 的 `depth_r_`），按平均半径会让近处顶点溢出、看起来像被平面切掉。
8. `pynq_dfx/board/shell_seg_BAD_reset.*`（未入库）复位极性错误，会让板子卡死，不要用。

## 9. Claude Code 上下文

- `CLAUDE.md`：Claude Code 打开本仓库时自动读取的项目规则摘要。
- `docs/claude/memory/*.md`：上一位开发者的 Claude 记忆（实测数据、决策、失败尝试）。想让你的 Claude 接着用：
  把这些文件复制到 `~/.claude/projects/<项目路径 slug>/memory/`（slug 是仓库绝对路径把 `:\/_` 等换成 `-`，
  打开一次 Claude Code 后该目录会自动出现）。其中 `server-hlab-access.md` 是原开发者的服务器，换人后路径要改。
- `docs/claude/session_1_dfx_migration_20260929.zip`：DFX 迁移阶段完整对话（shell、RP、两个 RM、上板）。
- `docs/claude/session_2_board_app_ui_20260930.zip`：板端程序、UI、性能、方向修复、交接的完整对话。
  解压后是 jsonl，每行一条消息，可以直接搜关键字。

## 10. 待办 / 可继续的方向

- seg 提速：只能从 PL 下手（解码器并行度 / 更大 pblock），或减少历史复位。
- seg→shape 串联：见第 7 节，需要重训 shape。先做双平面 Simpson EF 基线（UI 已有双平面 EF）。
- 第三个 RM：手势/打结识别（USB 摄像头），寄存器必须塞进 256 B。
- shape_top 2.0 实测 340k cycles，csynth 预计 209k：窗口 SRL FIFO 太浅导致停顿，可加深。
