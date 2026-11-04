# 结型 DW3/E3：SystemVerilog rev4 部署评审

最新状态（2026-10-08）：rev4 局部路由与时序修复已通过独立重新打开检查点验收。100MHz下路由错误0、setup WNS +0.013ns/TNS 0、hold WHS +0.001ns/THS 0，DRC无Error/Critical Warning，原static的pr_verify通过。时序裕量较小。功能网表一致性和时序约束比对也通过，未新增计算流水拍。详见 [最终时序ECO评审](diagnostics/rev4_timing_eco_20261007/TIMING_ECO_REVIEW.md)。rev5已停止并回退，自动跟进保持暂停；没有烧板，实板端到端20fps尚未验收。

修复过程：先将三个结果FF移至对应CARRY4同Slice的DFF，消除三条局部连接错误并[单独存档](diagnostics/rev4_local_20261007/LOCAL_REPAIR.md)。随后修正整机残留的OOC `create_clock ctrl_clk`，恢复真实PS FCLK0和抖动，保持10ns周期，诊断出10个真实内部setup失败端点。定向重接指定分支、局部LUT引脚优化及两份同拍配置FF关闭余下时序。相对时钟校正基线，原43827个primitive cell位置未变，仅新增两个FDRE，14个原网络路由有白名单内变化；未全局重新布局布线，未修改static。

以下保留原综合和首次物理实现历史报告；当前可交付物理结果以 `diagnostics/rev4_timing_eco_20261007/freeze_final/candidate.dcp` 为准，其SHA256为 `e0613ce30bcc0334b2acdbc795eee80d802a710c4158fc26146834cfc9d968fc`。仅从活动RTL重新实现不保证复现该局部ECO后的布局布线。

完整与部分bitstream已生成并下载，路径为 `diagnostics/rev4_timing_eco_20261007/bitstreams/dfx_full_knot_sv.bit` 和 `dfx_partial_knot_sv.bit`；完整SHA256清单随文件保存。归档SHA256 `028057d13f39ac71e2342c3ef50fff537aec07f59b6801f1b81f2a07dd436a45` 已核验，内部518个清单文件逐项一致，详见 `download_verification.json`。

## 模型与接口

软件模型仍为已接受的 256×320 结型 DW3/E3，W4A8，首层/检测头保留原 8bit 权重分解语义。不重训、不改变整数权重、舍入、残差缩放或输出坐标格式。

新核完全使用手写 SV 计算与控制；64 路 PW、48 路 DW，二者按行顺序执行，共享 8 路量化。原静态 shell 的端口保持不变；寄存器改用带签名的 SVK1 ABI，不能用旧 HLS first/count 驱动直接启动。

模型里的DW3是骨干深度卷积从5×5改3×3，原有3×3保留，1×1 PW不变。E3是中间展开通道目标3倍输入、向上对齐16且不超过原宽度；例如24→80并非严格3倍。块输出通道、残差和头结构保留；最大中间通道672→336。硬件64路并行是每拍处理能力，与软件模型的通道数是两件事。

### 手部任务复用边界

可以复用SV卷积、量化与缓存组织，但需要各任务独立权重、指令/尺寸/缓存规划和整数/RTL验证。关键点头含global mean和FC，当前结型指令流不能直接换权重覆盖。之前DW3/E3软件实验中，手检W4A8 AP50从0.72725降至0.66746；关键点axis PCK05从0.89339降至0.60190，NME从0.02486升至0.05821。这是原实验验证集结果，不是实板或独立测试集结论。手检可评估更温和缩减；关键点不宜直接沿用同等缩减幅度。尚未新开手部训练或物理实现。

## 四项存储调整

| 项目 | 旧 HLS64 | SV rev4 |
|---|---|---|
| bias/mult/shift | PW/DW 各三张宽表，共 16 BRAM36 | 每通道 bias24+mult32+shift6 打包 64bit；PW/DW 本地 RAM 合计 3 BRAM36 |
| 参数端口 | 运算输出时读取宽表 | 每个输出通道组扫描整行前，16拍预取到通道寄存器 |
| 输出缓存 | outb 2 BRAM，outh 512bit 宽浅缓存 7 BRAM | int8/检测头共用一个 64bit 输出 RAM，共 1 BRAM；连续 AXI 写回 |
| PW 权重 | 18 BRAM，模块 2240 LUT | 5 个 64bit bank，各 3 页×512 深度，共 15 BRAM；固定页选择 |
| DW 权重 | 3.5 BRAM，模块 1680 LUT | 64bit RAM，当前行核预取到寄存器，共 1 BRAM |

SV 仍有少量 LUTRAM/SRL 用于小状态/流水结构；未宣称全部状态都放入 BRAM。不同综合层级可能吸收周边逻辑，模块 LUT 差值只能辅助解释，总资源比较以下表为准。

## 实际 Vivado 综合

| 资源 | 旧 HLS64 | SV rev4 | 减少 |
|---|---:|---:|---:|
| LUT | 22,572 | 15,498 | 31.34% |
| FF | 21,380 | 10,638 | 50.24% |
| BRAM36 等效 | 78.5 | 42.5 | 45.86% |
| DSP | 88 | 48 | 45.45% |

rev4 OOC WNS +1.198ns，目标100MHz。该值不等于布线后时序验收。

## 验证与周期

- 原输入：22个融合块逐字节一致，完整调用 3,997,067 周期。
- 完整 AXI：随机读写停顿、4KiB分段、独立AW/W到达、CSR读写和IRQ清除通过；22块逐字节一致，4,085,727 周期。
- 第二个独立随机RGB输入：以已验证HLS C整数模型重新生成全部22块golden，SV AXI逐字节对拍全部通过。
- 独立Python标量oracle：512组×8lane=4096个量化边界样本通过，包含符号、24bit回绕、舍入、饱和和残差。
- 100MHz下带停顿AXI仿真为40.85727ms，50ms帧预算剩9.14273ms。模拟停顿不代表实板DDR延迟；实际预处理、后处理和DDR差异必须在余量内，才能端到端20fps。

## 物理实现

保留原 U 形 RP 和已布线 static。新 `pb_sv_compute` 覆盖底边+右臂的连续 L 区域，AXI/CSR 留在原RP内自由布局；PW/DW及共享量化不再被强制切入两个子区。

分区审计 LUT15,290/35,200=43.44%，BRAM42.5/100，DSP48/180，DRC无Error。

已完成布局及物理优化：

- 新计算区非空 Slice 5080/8800=57.73%。
- 同一个完整RP：旧HLS 7910/11000=71.91%；SV 5286/11000=48.05%。
- 计算区 LUT14655/35200=41.63%，BRAM42.5%，DSP26.67%。
- 仍有两个三级布局拥塞估计窗口（East Global111%、South Global112%）；无高于三级窗口。这是布局估计，不是最终冲突网计数。

首次全局实现目录：`sv_knot/runs/rev4/implementation`；局部ECO最终验收目录：`sv_knot/runs/rev4_timing_eco_20261007/verify_export`，上述门槛已通过。

## 复核与历史

`diagnostics/runs/rev4` 保存源码hash、算术/RTL/AXI及综合审计报告；`rev4_random` 保存第二输入报告。归档SHA256：`0e2409a0877720a97f185a09153b843aeaf68bc51c6affc037c5d1af2298327a`。当前本地RTL与已验证快照hash一致。

旧HLS64已最终失败：781条冲突net，WNS−4.204ns；报告已归档到原候选diagnostics/final，没有重跑。不得将旧结果当作SV结果。


## 历史：2026-10-07 22:08 CST，局部修复前的首次物理实现终态

最终未通过，没有重跑、未生成可交付 bitstream、未烧板。路由内部结束摘要报告 0 overlaps / 0 failed nets，但返回后 report_route_status 检出 3 条未完整连接且有 antennas/islands 的 net（38906/38909 fully routed），因此验收脚本正确停止于 route_failed。不能用内部摘要的零冲突宣称布通，也不能把这些称为旧 HLS 的资源冲突。

最终 WNS −0.338ns，TNS −5.452ns，39个 setup 失败端点；WHS +0.001ns，THS 0。负裕量集中在 clk_fpga_0 → ctrl_clk 路径；最差目的为 quantizer/lane[7].rm40/A[10]，路由延迟8.018ns，占94.619%。ctrl_clk 同域 WNS +0.023ns；当前设计仍部分布线，不能作为已通过时序验收。DRC 有 RTSTAT-2 / RTSTAT-5 Critical Warning；未到 pr_verify 与 bitstream 阶段。

只读打开 routed.dcp 核实3条网均为 CARRY4/O[3]，分别位于 DW lane6（SLICE_X104Y67）、PW pe3（SLICE_X69Y2）、PW pe5（SLICE_X70Y9），状态 ANTENNAS。诊断显示连接跨到 u_core 层级输入，尚不能据此确定根因。下一步应针对这3处进位链连接/层级映射及跨时钟命名路径核查，不应直接再改并行度或盲目重跑。

同一完整RP已布局Slice从旧HLS 7910/11000（71.91%）降至5286/11000（48.05%），减负方向有明确证据，但未实现最终部署。带停顿AXI仿真40.85727ms不是实板20fps验收。

终态报告和只读诊断归档于 sv_knot/diagnostics/final；服务端 routed.dcp 保留。归档SHA256已下载核验：a3b13bdf479203d98374ed3386c8b8337fa121de897c295c41069189eee9d55d。监视自动跟进在收尾后暂停。
