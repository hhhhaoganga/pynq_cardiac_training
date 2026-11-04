# P6 性能报告

目标：用实测数据写出性能报告，并判断瓶颈在哪一侧。

## 要做
1. `gate.py run` 生成 `report/perf.md`：端到端、内核、搬运各自耗时，ARM CPU 基线与加速比，时序与资源。
2. 看报告里的"内核占端到端时间"：
   - 高（>60%）：瓶颈在 PL，优化内核（流水、展开、位宽、并行）。
   - 低：瓶颈在 PS 侧，改 PL 没有用。先看报告头的「驱动」：
     - `python`：寄存器访问每次约 15 us，先让 `python skill/tools/cross_build.py` 输出 CROSS_BUILD_PASS（在 PC 上交叉编译，不要在板上编译），重新 `gate.py back P4 "启用 native 驱动"` 再测。
     - `native`：再减少拷贝和 flush，或加大每次调用的数据量。
   - 任务允许数据量可变时，报告里至少给 2~3 个规模的端到端时间和加速比（如 8K、64K、1M 元素）：小数据被固定开销淹没，大数据才看得出内核吞吐。
3. 每做一次优化：`gate.py back P2 "优化：..."` 走一遍完整关卡，再回到 P6 对比数字。

## 关卡
`perf_report.py --out report/perf.md` 打印 GATE_PASS。fake 板的数据会被拒绝。

## 不要
- 不要在报告里写没有测过的数字。
- 不测瓶颈就优化（见 pitfalls「先测瓶颈」）。
