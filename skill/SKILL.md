---
name: pynq-flow
description: Drive a PYNQ accelerator project end to end (contract -> golden -> kernel -> overlay -> board) with machine-checked gates. Use when building or debugging any PL accelerator called from PYNQ Linux.
---

# PYNQ 加速器工程流程（给智能体的入口）

本技能把一个 PYNQ 加速器工程拆成 7 个阶段。每个阶段有一张卡片、一个关卡命令。
**是否完成只看关卡输出，不看你自己的判断。**

## 每一轮都先做这一步

```bash
python skill/tools/gate.py status
```

它会告诉你：当前阶段、该读哪张卡片、关卡命令、已失败次数、未解决问题。
只读当前阶段的卡片，不要提前读后面的阶段。

## 铁律

1. 关卡没有输出 `GATE_PASS` 就不进入下一阶段。用 `gate.py run` 跑关卡，它会自动推进状态。
2. 同一关卡连续失败 2 次：停止小修小补。去 `skill/pitfalls.md` 按现象查表，
   用 `gate.py issue "假设：..."` 记下你的假设，再改。
3. 每做一个不显然的决定（数据排布、位宽、地址、为什么放弃某方案），
   用 `gate.py note "..."` 记录。下一轮的你会忘，记录不会。
4. 板上命令一律带超时：`board.py run` 默认 120 s。卡住的 AXI 访问会冻住整块板子。
5. 后面阶段发现前面的错（例如上板比对发现内核算错）：`gate.py back P2 "原因"` 回退，
   不要在后面阶段打补丁绕过。
6. 接口契约 `contract.yaml` 是唯一依据。驱动、测试、寄存器偏移都从它生成，不手抄。

## 阶段一览

| 阶段 | 卡片 | 关卡判定 |
|---|---|---|
| P0 契约 | phases/p0_contract.md | `gen_driver.py --check` 契约自洽 |
| P1 黄金参考 | phases/p1_golden.md | 参考模型自测 + 真实数据指标达标 |
| P2 计算核心 | phases/p2_kernel.md | csim/xsim 输出与黄金参考一致 |
| P3 Overlay 构建 | phases/p3_overlay.md | `check_build.py`：时序收敛、资源不超限、bit/hwh 齐全 |
| P4 上板冒烟 | phases/p4_smoke.md | `board.py smoke`：加载、IP 存在、寄存器回读、缓冲区、跑一次能结束 |
| P5 板上比对 | phases/p5_board.md | 板上输出与黄金参考一致 |
| P6 性能报告 | phases/p6_report.md | `perf_report.py` 用真板实测数据生成报告 |

## 开始一个新工程

```bash
# 在工程根目录（路径只用 ASCII），skill/ 放在根目录下
pip install numpy pyyaml
python skill/tools/gate.py init --board xilinx@192.168.2.99
python skill/tools/gate.py status
```

## 运行位置

- 本地电脑：Vivado / Vitis HLS、numpy 黄金参考、构建与报告解析、所有关卡命令。
- PYNQ Linux：Overlay 加载、MMIO、DMA、上板测试。只通过 `skill/tools/board.py` 访问（ssh/scp，带超时、root、PYNQ 环境）。
- 没有板卡时：`board.py smoke --board fake` 在 PC 上用黄金模型模拟 PL，只验证驱动逻辑。

## 其它命令

```bash
python skill/tools/gate.py note "n 固定为 1024"     # 记录决定
python skill/tools/gate.py issue "假设：DMA 长度位宽不够"
python skill/tools/gate.py resolve 1 "长度寄存器改成 23 位"
python skill/tools/gate.py back P2 "板上第 512 个元素起出错"
python skill/tools/board.py doctor                 # 板卡连通性/权限/pynq 版本
python skill/tools/board.py run "dmesg | tail -20"  # 板上执行（root，带超时）
```
