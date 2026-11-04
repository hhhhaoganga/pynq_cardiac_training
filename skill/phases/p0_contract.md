# P0 契约

目标：把"PS 和 PL 之间怎么说话"写成 `contract.yaml`，后面所有工具都只认它。

## 要做
1. `cp skill/templates/contract.yaml contract.yaml`，按你的算法改：
   - `buffers`：每块 DDR 数据的名字、dtype、shape、方向（in/out/inout）。
   - `registers`：AXI-Lite 偏移。HLS 内核的偏移**照抄** `<solution>/impl/misc/drivers/*/src/x*_hw.h`，不要自己推算；还没跑 HLS 就先按模板写，P2 拿到头文件后回来核对。
   - `streams`：用 AXI DMA 时填；纯 m_axi 留空。
   - `compare`：每个输出的比对规则。整数算法用 `exact`，定点/浮点用 `{atol: x}`。
2. 不确定的设计选择用 `gate.py note "..."` 记下（例如"n 固定 1024，不做可变长度"）。

## 关卡
`python skill/tools/gen_driver.py --check contract.yaml` 打印 GATE_PASS。

## 不要
- 不要在这一阶段写 HLS 或 Verilog。
- 不要为了过关删掉输出缓冲区或 compare 规则。
