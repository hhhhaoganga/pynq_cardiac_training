# P5 板上比对

目标：板上输出与黄金数据一致。

## 要做
1. `gate.py run`：推送 → 板上 `board_test.py` 用黄金输入跑 → 输出拉回 `board/out/` → `golden_compare.py` 比对。
2. 失败时看 `golden_compare.py` 的提示：
   - 全部不同 → invalidate / 地址寄存器 / 输出根本没写回。
   - 从第 k 个起全错 → 长度寄存器或 DMA 长度。
   - 数值集合相同、位置不同 → 转置 / 行列顺序 / 字节序。
3. 仿真对、板上错：差别只在接口和缓存，**不要先改算法**。依次查 flush/invalidate、寄存器偏移、64 位地址高位、DMA 长度。
4. 有真实数据的任务：再用真实样本跑一次任务指标（见 P1），记录 `gate.py note "真实数据 Dice=..."`。

## 关卡
`board.py test && golden_compare.py --actual board/out` 打印 GATE_PASS。

## 不要
- 不要放宽 compare 规则来过关；确需放宽时先 `gate.py note` 写明误差来源。
