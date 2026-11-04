# final1029 交接文档（2026-10-29 板上运行版本）

PYNQ-Z2 心脏外科手术训练平台：心腔分割、三维形状重建、CAMUS 双平面 EF、心电（AD8232）、JY62 姿态、两步结型识别、双手关键点、打结训练页。

本包就是 2026-10-29 板上正在运行的版本，和板子逐文件核对过：`board_app`、`hand_pipeline_v3_20261010` 共 350 个文件 md5 一致，两个 systemd 服务及全部 drop-in 一致，运行中的 `echo_demo` sha256 为 `a0dbb642…`，和 `elf/echo_demo` 相同。

更早的设计说明见 `source/HANDOFF_PYNQ.md`（系统结构、FPGA 构建、踩过的坑），本文只写现在的状态和怎么接着做。

## 1. 最近两次改动

### 1.1 final1029：HDMI 界面精简

只改了 `src/ui.cpp` 和 `src/i18n.cpp` 里的显示文字，算法、模型、位流都没动。完整差异见 `docs/ui_simplify.diff`，改后四个页面截图在 `docs/ui_screenshots/`。

- 顶栏：去掉标题下的「PYNQ-Z2 · 动态部分重配置 (DFX)」、右上角时钟和「未连接」。右上 PL 框改成一行「PL：心腔分割模块 / 三维形状模块 / 手部关键点模块 / 结型识别模块 / 重配置中…」，不再显示 `rm_seg`、`SV DW3/E3` 之类代号和切换次数、FCLK。
- 页脚：去掉「科研演示，非临床诊断用途 …」。这个位置仍用于临时提示和错误提示。
- 三维页：标题只剩「三维形状重建」；视窗里去掉模型名（如 Full_Heart_Mesh_866）、体积 / 相位 / 心电门控等说明行、三角面数和系统事件日志；去掉数据来源说明、系数卡标题后缀、累计校验行、心跳计数。体积仍在右侧「推理与重建」卡片里。
- 分割页：心电框去掉空闲时的提示。
- 摄像头页：去掉「PL 当前：…」和识别卡下方三行说明。
- 打结训练页：去掉两行模型状态（时序网络加载失败时仍会显示错误）和报告框里的心电提示。
- 保留：各页推理速度和耗时、分割面积 / EF / 体积等结果、拖动旋转提示、颜色条图例、打结 1–5 步说明。

改之前的程序在 `elf/echo_demo_final1028_before_ui`，源码可从 final1028 取。

### 1.2 final1028：结型分类器换成 edition6

只换了结型识别第二步的 PS 分类器，程序、位流、PL 检测器都没动。

| 项目 | final1027 | final1028 |
|---|---|---|
| `board_app/data/nn/knot_cls.nnp` | edition4（sha `29d561db…`） | **edition6（sha `a0989f00…`）** |
| `board_app/data/nn/golden_knot_cls/` | ed4 的 golden | ed6 的 golden |
| 旧分类器备份 | — | 同目录 `knot_cls_ed4_20261028.nnp`、`golden_knot_cls_ed4_20261028/` |

新分类器用 10-27、10-28 两批新拍的数据继续微调（见第 6 节）。两步端到端准确率（板上 PL 检测器 + 分类器，验证集）：

| 分类器 | 10-02 | 10-17 | 10-19 | 10-27 | 10-28 |
|---|---|---|---|---|---|
| ed4（旧） | 94.6% | 89.1% | 99.4% | 63.6% | 39.1% |
| **ed6（现在）** | 94.2% | 89.9% | 98.7% | 100% | 99.5% |

验证集按采集日期分组，每组独立统计；10-27、10-28 两组按 10 s 时间块切分训练与验证。

板上检查：`knot_cls_check` 输出 `KNOT_CLS_CHECK_PASS`（与训练端逐位一致，max diff 0；双线程约 51 ms/框），重启后日志有 `detect: knot_cls.nnp 7 M MAC`。

## 2. 板上配置

| 项目 | 内容 |
|---|---|
| 板端程序 | `~/hand_pipeline_v3_20261010/app_ecg/echo_demo`（本包 `elf/echo_demo`，同一个文件） |
| 源码 | `source/app_ecg_train/src`，与板上 `app_ecg/src` 逐文件一致 |
| 启动参数 | `--root /home/xilinx/board_app --hand-pl --no-demo`（drop-in `echo-demo.service.d/70-ecg.conf`） |
| 手部服务 | `hand-sv.service`，重检 `LAG_RETRY_S=0.35`（`hand-sv.service.d/60-v3.conf`） |
| 结型检测（PL） | `board_app/data/nn/knot_sv/`，ed3c 权重，与 final1020 相同 |
| 结型分类（PS） | `knot_cls.nnp` edition6 |
| 正反结 | `knot_throw.bin` |
| 心电 | 以回放启动（`80-ecg-replay.conf` 设 `ECHO_ECG_REPLAY`），界面上可切实时 / 回放；删掉这个 drop-in 就默认实时 |
| 位流 | 与 final1020 相同 |

drop-in 目录里 10/20/40/50/60 是历史版本，后面的文件覆盖前面的 `ExecStart`，真正生效的是 70 和 80。别随手删，`restore_board.sh` 会整目录替换。

## 3. 设备连接

| 设备 | 接口 | 作用 |
|---|---|---|
| 上位机 PC | 网口，TCP 5001（PC 设 169.254.1.100；板子 ssh 用 169.254.1.99，上位机连 169.254.1.150:5001，两个都是板子的地址） | 发 CAMUS 超声序列，收分割结果、EF |
| HDMI 显示器 | HDMI 720p60 | 系统界面 |
| USB 鼠标 | USB | 界面操作 |
| USB 摄像头 | USB，640×480 MJPEG | 拍打结训练器，手部关键点 + 结型识别 |
| AD8232 → Arduino Uno | Uno 250 Hz 采样，USB 串口 115200 | 实时心电，R 波、心率 |
| JY62 | UART1（Pmod JB，115200） | 手持角度，三维模型跟着转 |

图见本包 `docs/device_wiring.png`。

## 4. 恢复到板子

前提：官方 PYNQ-Z2 v3.1 镜像，PC 网线直连，PC 以太网设 169.254.1.100/16（不要用 .99 和 .150，那是板子的地址）。一步步的操作见本包 `board_guide.md`。在 Git Bash 里：

```
bash restore_board.sh 169.254.1.99
```

脚本会先把板上原有的 `board_app`、`hand_pipeline_v3_20261010` 和两个服务的 drop-in 改名备份（后缀 `_before_restore_<时间戳>`），再装入本版本、重启服务。包里已经有编好的 `echo_demo`，不需要编译；想从源码重编就加 `--build`（约 10 分钟）。过程中会问几次板子密码。

## 5. 改板上源码后重新编译

在板上 `~/hand_pipeline_v3_20261010/app_ecg`：

- 改了头文件：先 `rm -f build/*.o`，再 `make -j2`（约 10 分钟）。
- 只改 .cpp：直接 `make -j2`。
- 编完重启：**先** `sudo systemctl restart hand-sv`，等约 25 秒，**再** `sudo systemctl restart echo-demo`。
- 不要只重启 `echo-demo`：手部推理在 `hand-sv` 服务里，`echo_demo` 和它之间有一条连接，单独重启 `echo_demo` 会把连接打断，`hand-sv` 锁进故障状态，日志刷「Hand backend fault latched」，手部关键点和打结训练页都用不了。出现这种情况按上面的顺序两个都重启即可恢复。

改完程序要跑三道门禁（都在板上 `~/board_app` 下）：

- `python3 tools/proto_check.py` → `PROTO_CHECK_PASS`
- `sudo python3 tools/ui_mouse_check.py` → `UI_MOUSE_CHECK_PASS`
- `sudo sh tools/demo_toggle_check.sh` → 现在必然 `DEMO_TOGGLE_FAIL`，可忽略：服务以 `--no-demo` 启动，页脚已经没有「本地演示」开关，脚本点到的位置现在是「心电：回放录制」按钮（点两次，切过去又切回来，不影响状态）。以后若恢复本地演示开关再用它。

`proto_check` 一定要先把界面切到「① 心腔分割」页再跑。停在摄像头页或打结训练页时，手部 / 结型模块一直在抢 PL，分割逐位比对会报 FAIL，这不是程序坏了。

## 6. 结型识别：接着拍数据、微调、上板

两步识别：PL 检测器在整幅 320×256 上找结、取最高分的一个框 → PS 把框按 2 倍边长裁成 96×96 → 分类器判单结 / 方结 / 三重结。上一轮的经验是**检测器已经够用（定位率 98–100%），问题都在分类器**，所以通常只需要重训分类器。

### 6.1 拍数据

脚本 `tools/capture/capture.py`（本机原位置 `D:\PLD\seunet_3d_0930\knot_data\capture.py`）。PowerShell：

```
cd D:\PLD\seunet_3d_0930\knot_data
D:\python311\python.exe capture.py --list
D:\python311\python.exe capture.py --cam 1 --out raw\data1029
```

一定要加 `--out` 指定新文件夹，不加会存进默认的 `raw\data1019`。窗口里按 `1/2/3` 切到单结 / 方结 / 三重结，按 `a` 开关连拍（15 张/秒），`q` 退出。拍摄时变换背景、光线、角度。

### 6.2 标注与修正

用 X-AnyLabeling 标框，导出 YOLO txt，三类放三个文件夹（例：`raw\data1028\labels_knot1/2/3`）。标出来常有多框、类别错，用脚本统一：每个文件夹改成对应类别（knot1→0 single，knot2→1 square，knot3→2 triple），多框只留一个（优先类别本来就对的，再取面积最大）。

```
D:\python311\python.exe fix_labels_1028.py --root raw\data1028 --suffix "" --dry-run
D:\python311\python.exe fix_labels_1028.py --root raw\data1028 --suffix ""
```

脚本在 `tools/knot_two_stage/finetune_1028/fix_labels_1028.py`。改之前自动把原始 txt 备份到 `<root>\labels_backup\`，备份已存在时拒绝运行。

本机原始数据：`D:\PLD\seunet_3d_0930\knot_data\raw\data1027`、`data1028`（各约 1.2 GB，未放进本包）。

### 6.3 服务器训练

训练只在服务器 GPU 上跑（本机太弱）。服务器 `hlab`，账号 `lizx`，工作目录 `~/knot_hand_20261002`，Python `~/.conda/envs/heart25d/bin/python`，需要 `PYTHONPATH=$PWD/pylib`。ssh 密钥找账号负责人要，不在本包里。

服务器上的数据：`data/knot/edition6/`（所有天的图 + YOLO txt，硬链接）+ `data/knot/split_ed6.json`（train/val 文件名列表）。新数据加进来的步骤和脚本都在 `tools/knot_two_stage/finetune_1028/ed6/`：

1. 把修好的 `labels_knot*` 里的 png+txt 传到服务器 `data/knot/data10xx_labeled/`。
2. 照 `make_ed6.py` 生成 `edition7` + `split_ed7.json`：旧 split 原样保留，新数据按类、10 秒分块、每 3 块 1 块进 val，避免相邻几乎一样的帧同时出现在 train 和 val。
3. 照 `run_ed6.sh` 训练：分类器从上一轮 float 权重继续，float 15 轮 + QAT 10 轮（`knot_crop_cls.py` → `knot_crop_qat.py`，`--select` 写上所有日期，按各天平均准确率选模型）；QAT 结束会自动导出 `knot_cls.nnp` 和 golden，并做整数路径校验（`INT ... argmax agree` ≈ 0.998 正常）。
4. `knot_two_stage_eval.py` 做端到端对比，`--det` 用板上检测器 `runs_ed3c_dw3/qat/best.pth`，`--cls` 分别给旧 / 新 nnp。

耗时：分类器约 10 分钟；检测器（若要训）一轮约 2–3 分钟、22 轮约 1 小时，端到端评估一组约 5 分钟。服务器 4 张卡共用，跑之前先用小矩阵测一下每张卡的速度，挑最快的。脚本都用 `nohup` 后台跑，本机关机不影响。

### 6.4 上板（只换分类器）

1. 把新的 `knot_cls.nnp`、`knot_cls_in.u8`、`knot_cls_out.f32` 先放到板上一个暂存目录，例如 `~/knot_cls_new/knot_cls.nnp` 和 `~/knot_cls_new/golden_knot_cls/`。
2. 在暂存目录先校验：`~/hand_pipeline_v3_20261010/app_ecg/build/knot_cls_check ~/knot_cls_new`，要看到 `KNOT_CLS_CHECK_PASS`。`build/` 不在本包里，没有的话按 `tools/knot_two_stage/knot_cls_check.cpp` 文件头的命令先编一次。
3. 备份板上现有的 `knot_cls.nnp` 和 `golden_knot_cls/`（改名加日期），再把新文件拷进 `~/board_app/data/nn/`。
4. `sudo systemctl restart echo-demo`，看日志 `journalctl -u echo-demo` 里有 `knot_cls.nnp 7 M MAC`。

回退就把备份拷回去再重启。检测器若要换，需要重新打 PL 指令包（`tools/knot_two_stage/build_knot_sv_pkg.py`），步骤复杂很多，不建议轻易动。

## 7. 上位机

本包 `host/`（`final1029不含上位机.zip` 不含这个文件夹，另行拷贝）。用 Python 运行 `host/camus_stream_host.py`，说明见 `host/README_交接说明.md`。TCP 5001 走直连以太网，不设鉴权。

## 8. 目录

| 路径 | 内容 |
|---|---|
| `board_snapshot.tgz` | 板上 `board_app`、`hand_pipeline_v3_20261010`、两个 systemd 服务及 drop-in（含 `echo_demo` 可执行文件） |
| `restore_board.sh` | 一键恢复 |
| `board_guide.md` | 自己上板的步骤：连板、重启服务、换模型、改代码重编、整版恢复 |
| `elf/` | `echo_demo`（= 板上运行版）、`echo_demo_final1028_before_ui`（界面精简前）及更旧版本 |
| `source/` | 板端 C++ 源码、PL 工程（HLS / Vivado 输入）、早期交接文档 |
| `bitstreams/` | 位流 |
| `models/knot_two_stage/` | `classifier_ps_ed6`（**板上在用**）、`classifier_ps_ed4`（上一版）、`detector_pl_ed3c`（**板上在用**）、`classifier_ps_ed5_not_used`、`detector_pl_ed6_candidate_not_used`（mAP 更高但两步准确率不比现在好，没换） |
| `models/` 其他 | 手部检测、关键点、正反结 TCN 等 |
| `tools/knot_two_stage/finetune_1028/` | 本次两轮微调的标签修正脚本、建数据集脚本、训练脚本、日志、split、评估结果 |
| `tools/capture/` | 拍数据脚本 |
| `data/` | 心电录制、打结录像轨迹 |
| `benchmarks/` | PL 和 CPU 分割对比结果 |
| `docs/device_wiring.png` | 设备连接关系图 |
| `docs/ui_screenshots/` `docs/ui_simplify.diff` | 精简后的四个页面截图、界面改动差异 |

## 10. 实测参数

| 项目 | 数值 |
|---|---|
| 结型帧端到端 | 约 190–300 ms（PL 检测约 44 ms + PS 分类约 50–130 ms + 解码/裁剪），约 4–5 fps |
| `knot_cls_check` | 与训练端逐位一致，max diff 0；双线程约 51 ms/框 |
| 分割（PL，W4A8） | 69 ms/帧，28.7 fps（ARM A9 基线 549 ms/帧，1.82 fps） |

日志时间戳取自板子本地时钟，按先后顺序读。
`source/HANDOFF_PYNQ.md` 第 8 节记录了静态外壳、partial bin 字节交换、`/tmp/echo_demo_input` 写入超时等构建要点。
