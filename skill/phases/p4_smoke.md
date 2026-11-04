# P4 上板冒烟（PYNQ Linux）

目标：overlay 能加载、寄存器能读写、内核跑一次能结束。这一阶段不看结果对错。

## 要做
1. 板卡准备（一次性）：PC 上 `ssh-copy-id xilinx@<板卡IP>`；板上免密 sudo，或在 PC 设置环境变量 `PYNQ_SUDO_PASS`。
2. `python skill/tools/board.py doctor`：ssh / sudo / pynq / 磁盘全部 ok。
3. 可选：先 `--board fake` 在 PC 上跑一遍，验证驱动逻辑（不需要硬件）：
   `python skill/tools/board.py smoke --board fake`
4. 真板：`gate.py run`（即 `board.py smoke`）。它会推送 `board_pkg/` 到 `~/skill_run/<name>/`，然后以 root 运行 `board_smoke.py`。

## 读失败信息
`board_smoke.py` 按 env → files → overlay → registers → buffers → run 顺序检查，最后一个 `[smoke]` 行就是出问题的步骤。`SMOKE_FAIL:` 后面是原因。

## 关卡
`board.py smoke` 打印 GATE_PASS。

## 不要
- 不要在板上手动 `python3 xxx.py` 而不加 `timeout`：AXI 访问挂住时整块板会死机。
- BOARD_TIMEOUT 后先 `ping`；不通就断电重启，不要连续重试。
