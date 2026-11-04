# 结型 SV 核实板部署与界面集成

2026-10-08（北京时间）。用户明确要求重新烧录已通过实现的结型版本，并在原 HDMI 界面显示摄像头与检测叠加。本次已经完成运行时加载，并通过 systemd 配置在服务启动时选择该版本。没有重新综合、布局布线或修改 static。

## 原因与最终状态

连接时板上仍是旧 `echo_demo`，固件只有 seg/shape；日志显示摄像头页面在执行 PS 手部整数推理，并非新 SV 结型核。新的 SV 位流此前已生成并归档，但摄像头推理入口还未完成 C++ 集成。

当前 `echo-demo` 使用 `--knot-pl --no-demo` 启动，加载已发布的完整结型位流，进入摄像头页面并选中“结型识别”。顶部显示“PL：结型 SV DW3/E3”。手部模型文件仍保留，当前未运行手部识别。

- 模型：256×320（高×宽）DW3/E3 W4A8，原已验证参数，无重训；PW64/DW48，100MHz。
- 完整 bin SHA256：`fb2f90a2ef0a04c7f8b257b16cea2b056cb87eefb2a8b9f2ac67cf2e321fa621`。
- 部分 bin SHA256：`66909b2a646ef66d60ea3fc0bb00550d1757db7506332ca7489a84e27dd47348`。
- 板端程序 SHA256：`2fc23ee417998aab5e069f83da37ccf8444ffc52d4a1c06ddf2baa25a4072f84`。
- 板上 `/home/xilinx/board_app/data/nn/knot_sv` 保存经过 SHA256 校验的程序、权重、参数、输出反量化比例和 golden。
- 服务配置：`/etc/systemd/system/echo-demo.service.d/10-knot-sv.conf`。本次首次实板验收设置 `Restart=no`，避免启动对拍失败后自动反复加载。

## 集成方式

新增 `src/knot_accel.cpp/.hpp` 使用带签名的 SVK1 寄存器接口，XRT 连续 DDR 缓冲区、缓存同步、RGBX 输入及 40×32×7 检测头反量化。程序 image、指令和 golden 与已通过 RTL 验证的 rev4 哈希一致；program.json 后补的输入/输出描述已单独核对原描述符。

所有 RP 操作仍由原 worker 单线程串行处理。摄像头识别线程通过队列提交结型任务，不直接与分割或三维线程争用 RP。分割、三维和结型的 partial 切换保持原 static。结型模式会停用后台自动轮换；切到其他页面会停用摄像头识别。界面保留框、类别、置信度叠加，并分别显示应用推理耗时和 PL 核耗时。

## 验证结果

1. 主机上，原 fixture 的 RGBX 打包和检测头反量化，与原 256×320 NNP 整数参考的 40×32×7 输出完全一致，最大差异 0。
2. 实板启动读取签名 `SVK1`；所有 22 块输出先填充哨兵，再实际运行并逐字节比较 golden，通过。记录为 `KNOT_SV_GOLDEN_PASS blocks=22 cycles=4372493 kernel_ms=43.748`。
3. 原协议回归 `PROTO_CHECK_PASS`：分割串行、流水、切回后各 8 帧均零差异；三维 150 例零差异；seg/shape 显式切换通过。
4. 从 seg/shape 再切回 knot-sv 成功，摄像头 640×480 在线，持续产生来自 PL 的推理结果，fpga_manager 为 operating。最终截图已下载，当前拍摄场景未检测到结；尚未以现场正样本验收相机检测准确率。

201 条抽样推理日志的核耗时中位数为 44.391ms，应用推理耗时中位数 108.076ms、最小 90.147ms；日志包含启动和重配置等异常长帧，不能仅据这些抽样换算稳定端到端 fps。**目前整链路未达到 20fps**：摄像头采集、PS 预处理、调度和显示开销仍需优化。摄像头 30fps 不等于目标检测 30fps。

证据见同目录 `board_deploy_20261008/` 下的 `board_validation.json`、`activation_and_runtime.log`、`proto_check.log`、`installed_service.txt`、`installed_sha256.txt` 和 `knot_sv_camera_final.png`。板卡没有正确校时，原 journal 中的 May 04 时间不是本次主机日期。

## 操作与保留

通常已默认进入摄像头结型页面；手动选择路径为“③ 摄像头 → 结型识别”。重载当前完整位流和界面可用 `sudo systemctl restart echo-demo`。

部署前的源码、程序、固件和服务主配置已保存于板上 `/home/xilinx/knot_release_20261008/pre_integration_backup.tgz` 与 `echo-demo.service.before`。独立构建目录为其下 `candidate/`。原已通过时序的位流和 DCP 归档不变。
