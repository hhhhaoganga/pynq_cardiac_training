# P2 计算核心（HLS / RTL，在本地 PC 上跑）

目标：内核在仿真里与黄金数据逐项一致，并导出 IP。

## 要做
1. 写内核。HLS 推荐接口：数据指针 `m_axi`（每个指针独立 bundle），标量与控制 `s_axilite port=return`。
   流式数据用 `hls::stream<ap_axiu<32,0,0,0>>` + `axis`，最后一拍必须置 TLAST（参考 `skill/templates/stream/hls/`）。
   Windows 上用 `skill/templates/hls/run_hls.bat` 启动 HLS（处理 `X:\dev\null` 与环境变量问题）。
2. 写 C/C++ testbench：读 `data/golden/<输入>.bin`，调用内核，把每个输出 `fwrite` 到 `sim/out/<名字>.bin`。
   RTL 流程同理：testbench 用 `$readmemh` / `$fwrite` 读写同名文件。
3. 跑 C 仿真 → 综合 → C/RTL 联合仿真 → 导出 IP（`export_design -format ip_catalog`）。
4. 打开生成的 `x*_hw.h`，逐个核对 `contract.yaml` 的寄存器偏移；不一致就改契约并重跑 P0：`gate.py back P0 "偏移按 hw.h 修正"`。
5. 记录综合报告里的延迟和 II：`gate.py note "latency=..., II=..."`。

## 关卡
`golden_compare.py --actual sim/out` 打印 GATE_PASS。

## 不要
- 不要修改黄金数据去迁就内核。
- C 仿真过了、联合仿真没跑就进 P3：接口时序问题会拖到板上才暴露，代价大得多。
- 路径里不要有中文或空格（Vivado/HLS 会失败，见 pitfalls）。
