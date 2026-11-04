# SV rev5：AXI边界隔离与局部进位链配对

**已按用户要求中止并回退。** rev5不是最终路由失败：在布线中途取消，未获得最终route/timing结果。旧快照和日志保留，当前活动代码为rev4；自动跟进暂停，不再启动实现。取消报告SHA256：9b1652f0016325297772f53da96fda1b533855732eb423bb4d158ff48bb2346d。

2026-10-07。模型、256x320尺寸、64路PW、48路DW及算术流水保持原验证语义。

## 修改

- 新增 knot_elastic2 两槽寄存FIFO，在 RP 内的 AXI R/W 边界隔离数据和握手。RDATA/RRESP/RLAST共67bit，WDATA/WLAST共65bit；输入ready与输出valid只依赖本地状态。满速时一拍一beat，满队列释放时可能有一拍恢复间隔。
- 仅两个边界实例保留 dont_touch，防止边界存储被吸收到远端DSP/BRAM；不对全设计施加 dont_touch。
- 三处诊断出的bit11接收FDRE与实际CARRY4/O[3]驱动建立同Slice相对宏，BEL为CARRY4/DFF，全局位置仍由布局器选择。连接不符合预期就停止。布局和物理优化后再次检查同址关系。
- 没有修改 static，也没有把时序路径设为 false_path。

## 已验证

| 项目 | 结果 |
|---|---|
| 独立量化算术边界 | 4096样本 PASS |
| core原输入 | 22块逐字节 PASS |
| AXI原输入随机停顿 | 22块 PASS；4,096,442周期 |
| AXI第二随机输入 | 22块 PASS；4,096,442周期 |
| AXI无停顿 | 22块 PASS；4,027,566周期 |
| 独立缓冲测试 | 满队列停顿、同时出入、输出稳定、复位清空 PASS；复位有意丢弃1个旧队列项 |
| 实际综合 | 15,607 LUT，10,910 FF，42.5 BRAM36等效，48 DSP |
| 综合WNS | +1.198ns（不是最终布线时序） |

相对rev4增加109 LUT、272 FF；BRAM/DSP不变。R缓冲138 FF、W缓冲134 FF。随机停顿耗时40.96442ms@100MHz，比rev4多0.10715ms。仿真50ms帧预算剩9.03558ms，不代表实板20fps通过。

## 实现门槛与状态

continue_rev5.py监督验证与资源评审：原static审计、寄存隔离与配对DRC检查全部通过才启动一次实现。run_implementation.py还检查两个额外测试、源码一致性、综合时序、资源和周期预算。任一失败停止，不自动重试。

原static审计及边界/配对预检查已通过：R侧138 FF、W侧134 FF保留，输入RDATA/RVALID/RLAST/RRESP与WREADY仅连接对应边界缓冲，没有旁路到计算单元。2026-10-07 22:33 CST启动唯一一次实现，监督PID2277946，已进入placement。

当前报告以服务器 runs/rev5/boundary_review 和 runs/rev5/implementation 为准。物理实现尚未验收，不能将rev4的剩余3条ANTENNAS当新版结论。

验证归档 review_rev5.tar.gz 的SHA256为 1a626ebdd2ae1db52173888d2c08afbad01035b07fa9a43b210aaefac49c9bdf；已下载并校验，解压到 diagnostics/rev5_review。终态实现报告将另行归档。

## 22:39 CST 布局与布线检查

布局及物理优化完成。三处配对约束实际生效：DW lane6位于SLICE_X102Y6，PW pe3位于SLICE_X34Y15，PW pe5位于SLICE_X32Y21；每对CARRY4与DFF均同址。不能据此直接判定最终路由已修复。

完整RP非空Slice为5359/11000=48.72%（rev4为5286/11000=48.05%）；计算区5100/8800=57.95%。布局估计只有一个三级拥塞窗口，East107%，主要为量化器与core；没有高于三级窗口。报告已下载到 diagnostics/rev5/placement。

目前route_design迭代中：第0轮overlap节点6312→1861，第1轮重新展开后3575；中间WNS−0.641ns/TNS−45.565ns。此时路由尚不完整，不能当成最终时序，也不能拿它与rev4最终3条ANTENNAS直接比较。监督进程存活，未重跑。
