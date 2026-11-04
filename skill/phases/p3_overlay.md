# P3 Overlay 构建（Vivado，在本地 PC 上跑）

目标：`build/out/` 下得到同名的 `.bit` + `.hwh`，以及时序/资源报告。

## 要做
1. Block Design：ZYNQ7 PS（或 Zynq US+ PS）+ 你的 IP + AXI Interconnect/SmartConnect；m_axi 接 PS 的 HP/HPC 口，s_axilite 接 GP 口。用 DMA 时加 AXI DMA（不用 SG，`c_sg_length_width` 设 23，否则单次最多 16 KB）；可直接改 `skill/templates/hw/build_overlay.tcl`（m_axi）或 `skill/templates/stream/hw/build_overlay.tcl`（AXI DMA）。
2. 板卡预设：PYNQ-Z2 要装 board file 并 `apply_bd_automation`，否则 DDR/时钟参数是错的，上板可能直接卡死。
3. 记下 IP 实例名，必须等于 `contract.yaml` 的 `ip`（PYNQ 的 `ip_dict` 键名）。
4. 生成比特流后，在 Vivado Tcl 里输出：
   ```tcl
   report_timing_summary -file build/out/timing.rpt
   report_utilization    -file build/out/utilization.rpt
   ```
5. 拷贝 `<proj>.runs/impl_1/*.bit` → `build/out/<name>.bit`；
   拷贝 `<proj>.gen/sources_1/bd/*/hw_handoff/*.hwh` → `build/out/<name>.hwh`（**同名**）。

## 关卡
`check_build.py --dir build/out --contract contract.yaml` 打印 GATE_PASS：WNS/WHS ≥ 0，资源 ≤ 90%，hwh 中有该 IP 且寄存器偏移与契约一致。

## 不要
- WNS < 0 也拿去上板"试试"：能跑也会偶发错。先降 PL 频率或加流水。
- 只换 .bit 不换 .hwh。
