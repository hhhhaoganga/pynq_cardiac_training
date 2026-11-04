# 原模型双 ROI：SV、DDR 与 PS 优化

2026-10-08。用户要求保留原关键点精度，采用已认可的双 ROI 跟踪，目标双手每帧都有新结果、至少 14fps。此目录与已发布结型位流隔离；当前没有烧录或改动板上结型服务。

**最新终态：2026-10-08 17:28，北京时间，一次布局布线通过，完整/部分 bitstream 已生成、下载并逐项 SHA256 校验。** 路由错误0、setup WNS +0.075ns、hold WHS +0.019ns、DRC无Error/Critical Warning，原static的pr_verify通过。最终计算区域Slice为6222/8800（70.70%），不是21189个Slice；21189是OOC LUT数。最终拥塞报告未发现level 3以上窗口。时序余量较小，交付以归档routed.dcp及位流为准。实板双手14fps尚未验收。

交付物在 `diagnostics/implementation/`：`dfx_full_hand_dual_roi_sv.bit/.bin`、`dfx_partial_hand_dual_roi_sv.bit/.bin`、`routed.dcp`及全部报告。完整bit SHA256 `fc8b6e4964c5b9fcc48a93ad909984c42ad5c29e11ce9de8fb42f0744a7bf911`，完整bin `d4f26f768a869e6ef651f6171ce045ca8072b0c54170c29a27e7982bb2ffee74`。Linux加载bin的字节序处理仍须沿用原board_app/hw层，不能把下载位流等同于已部署。物理归档37,441,114字节、SHA256 `af80c5fe0b44e03c6affbe10dc1c64fa5562e3b043967987d249b869ebda3ad1`，58个内部文件和6份位流清单条目校验通过，见 `implementation_download_verification.json`。

## 已验证的结果

原 `landmark.nnp` 保留 224×224 输入、所有通道及 3×3/5×5 卷积，145,605,824 MAC/ROI，无训练或重新量化。SHA256 为 `0b1f66279490344e4756b69e9928a8080255e256e1bdf6a04be4b36410e81e3f`。原手检 SHA256 为 `dadbaeaeb1e414cfbb837d8e692d5f15bfb28911a3c63eb4c4c7064a06bf08be`。

- PW128（16 输出×8 输入，阵列延迟 6 拍）、DW80（16 通道×5 横向 tap，阵列延迟 4 拍）；时钟目标 100MHz。RAM 及控制等待另计，不能把阵列拍数视为全核流水深度。
- 六行 512×128bit 行缓存，PW 权重 10 个 1024×64bit bank，DW 权重 1536×64bit、联合参数、64bit 输出。保持原量化点，三个宽融合块在已有 int8 E 输出处分开，共 19 块/ROI。
- 两只手按块交替执行，同一块权重/参数只加载一次，所有激活地址分开。视频双 ROI 和随机双 ROI 各 38 块与原 NNP 逐字节一致。基线完整串行两个 ROI 也通过。
- 原手检 256×320 在同一 RTL 上通过视频和随机输入各 23 块 AXI 对拍；唯一超宽行拆成 40＋40 输出列，保留 81/80 列展开输入及 halo。无需为手检和关键点重新配置 PL。

| 完整双 ROI 实验 | 周期 | 100MHz 条件下时间 |
|---|---:|---:|
| 两次完整串行，理想核接口 | 5,702,418 | 57.02418ms |
| 按块共享权重，理想核接口 | 5,608,302 | 56.08302ms |
| 共享权重，完整 AXI 无停顿 | 5,633,835 | 56.33835ms |
| 完整 AXI 随机停顿，视频/随机输入 | 5,721,973 | 57.21973ms |
| AXI 每两拍最多一个 beat，再加随机停顿 | 6,373,937 | 63.73937ms |

最后一行相当于 100MHz、64bit 数据通道峰值 400MB/s 的仿真，并非板端 DDR 实测。每帧 14fps 的 71.42857ms 预算只剩 **7.68920ms** 给 PS、缓存维护、相机及调度等。重新检测还有独立开销：随机停顿手检为 4,483,593 周期/44.83593ms，恢复帧不能混报为稳定跟踪帧率。

共享后每帧 DMA 传输 4,618,368 字节，相比串行 5,367,776 字节减少 749,408 字节（约13.96%）；不代表同等百分比的总推理加速。AXI 实测仿真读434,384、写142,688个64bit beat，与微程序统计完全一致。

完整核 Vivado OOC：**21,189 Slice LUTs、14,294 FF、54.5 BRAM36 等效块、48 DSP**，WNS +1.206ns。此处不是已布局 Slice 数，不是布线后时序。原 static 导入审计通过，继承真实 `clk_fpga_0` 100MHz 时钟，未保留额外 OOC 主时钟。静态 DCP SHA256 `27a27ee1762ecae4a9d4e184de08250a2b8f43b2176f966a8ecf33fe9ad395a3`。

## PS 与跟踪

`batched_tracking.py` 复用已认可 `TwoHandTracker` 的质量门槛、余量、平滑、ID 与失效恢复规则，只将当帧两个有效 ROI 作为一个 batch 提交。两段视频采用原 ceil 因果采样、14Hz，共151＋181帧；与本次同环境下串行原模型逐帧比较，所有点、置信度、决策、调用计数完全一致。这是等价性检查，没有新增标注精度结论，也不是板端速度测试。`tracking_validation_round_sample.json` 只保留早期不同采样相位的诊断，验收以 `tracking_validation.json` 为准。

`preprocess.py` 保留原 OpenCV 浮点仿射、双线性插值与零边界，在预分配 BGR scratch 中裁剪，再直接写 RGBX DMA 输入视图；128 组含边界 ROI 与原裁剪逐像素相同。手写旧版 5-bit 插值与 OpenCV 5 accurate 模式不一致，已退出活动路径，仅存为 `ps/crop_rejected.txt` 诊断。

`ps/hand_ps.cpp` 只执行原整数均值及四个 FC 头。按连续行累加、复用缓冲，ARM NEON 路径用于 FC int16 点积。四组全模型尾部和64组随机/极值特征测试与独立整数参考零差异。x86 主机验证通过；**ARM NEON 分支尚未实机执行**，主机耗时不得换算为板端速度。

`sv_driver.py` 提供独立 SVH1 双 ROI 包加载/执行接口，验证包哈希，拒绝结型 SVK1。每帧只 flush 两个 RGBX 输入（401,408字节）、invalidate 两个末端特征（65,856字节）。程序/参数常驻分配区，只在初始化整体同步。范围维护及错误 ABI 的模拟 MMIO 检查通过。该接口需要板端分配/缓存维护适配器和唯一 RP 所有者；尚未接入现有 HDMI 摄像头服务，也未把 Python 主机计时当 ARM 计时。

板卡 `169.254.1.99` 本次只读 SSH 连接超时，因此真实 DDR、ARM 裁剪/尾部、缓存同步及显示端到端测量尚待完成。不能据上述仿真宣称双手14fps已经验收。

## 物理实现与复现

服务器根：`/home/lizx/knot_hand_20261002/integration_knot_dw3/pynq_dfx/sv_hand_dual_roi_20261008`。`run_validation.py` 已完成六组关键点 RTL/AXI 验证与 OOC；`run_detector_validation.py` 完成原手检验证；`run_bandwidth.py` 完成限制吞吐实验。`review_resources.py` 审计原静态壳。

`run_physical_once.py` 在以上条件及软件验证通过后，只执行一次 `implementation/` 内布局布线，保存精确源文件和输入 DCP 哈希。只有路由零错误、setup/hold非负、DRC无Error、pr_verify通过才生成备用 bitstream。失败保存诊断，不自动更换策略或重新实现；不修改 static，不烧板。当前物理状态查看该目录 `status.json`、`stage.txt`、`implementation.console`。

`prepare_sources.py`、`prepare_compiler.py`、`prepare_tests.py` 为初始引入脚本。`compile_single.py` 后续已加入手检分条支持，必须直接维护，不能用旧引入脚本覆盖。`build_detector.py` 已确认扩展前后关键点 memory.bin 与微程序字节不变。

用本地 `D:/anaconda/python.exe server_link.py status` 检查服务器。验证归档由 `archive_validation.py` 生成，下载后同时核对归档哈希与内部文件清单。后续物理报告独立归档，勿与已成功结型或历史 HLS 结果混淆。

本次验证归档已下载至本目录并解包到 `diagnostics/validation/`：65,059,626字节，SHA256 `91dadb9fa04321de7bdbd81932d7c6edd03eeb0b39ceb8ad86e57c13f0731a18`，228个内部文件逐项校验通过，见 `download_verification.json`。物理监督PID1621823已完成，阶段状态为complete。布局布线终态收尾后自动跟进暂停，后续仍需板端PS/UI接入与整链路测量。
## 2026-10-08 板端接入更新

已按用户授权加载实板，并将 `echo-demo` 默认启动改为 `--hand-pl --no-demo`。手检与双ROI卷积均执行SVH1，PS保留原整数均值/FC、裁剪、跟踪及显示；不回退到ARM全模型。结型SVK1仍可通过原界面切换。发布目录 `/home/xilinx/hand_release_20261008`，原结型二进制未覆盖，原启动配置和源码已有备份；禁用 `20-hand-sv.conf` 可回到旧结型启动。开机等待后端就绪，再加载手部全位流并对拍，防止旧socket误报就绪。

实板视频/随机输入双ROI各38块、手检各23块、单ROI19块均逐字节通过；ARM NEON尾部68例零差异。原版OpenCV4.5裁剪存在版本差异，新增`ps/accurate_crop.cpp`兼容OpenCV5 accurate输入，NEON四像素并行、边界快速填充、取整临界值精确补算，128组实板ROI全字节一致。

最终一次隔离板测：双ROI裁剪24.486ms，缓存同步+核+输出同步63.057ms（核61.514ms），PS末端2.848ms；含坐标和Python组织的完整后端平均94.378ms。标量版本平均128.799ms。固定真实双手图连续8次保持两手。**这些数据未包含摄像头/跨进程传帧/HDMI显示，端到端14fps尚未达标。** 分段报告在`diagnostics/board_validation.json`及板端`runtime/*validation.json`、`ps_stage_profile.json`，裁剪PL方案评审见`PL_CROP_REVIEW.md`。以下内容中的“未烧板/未接入/ARM未执行”是此前阶段记录，以本更新为准。

