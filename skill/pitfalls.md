# 踩坑清单

`gate.py run` 失败时，用每节的「关键词」去匹配失败日志并列出相关条目。连续失败 2 次必须先读这里，再用 `gate.py issue "假设：..."` 记录，然后才改代码。

来源标记：**实测** = 本仓库（PYNQ-Z2 超声分割 DFX 项目）开发中真实遇到并验证过的修复；**通用** = PYNQ/Vivado 的常见问题，修复方式来自官方文档或广泛经验，本项目没有逐条复现。

## 黄金 PASS 但真实数据全错
关键词: 转置, 数值集合相同, dice, 方向
- 现象：黄金比对逐位一致，换真实样本后结果乱掉（分割掩码像被打乱）。
- 原因：黄金数据和模型使用同一种（错误的）方向/排布约定，比对只能证明"硬件 = 模型"，证明不了"模型 = 任务"。
- 确认：拿真实样本算任务指标（Dice/准确率），并画出输入输出看方向。
- 修复：P1 的 `independent_check` 里加真实数据指标断言；方向转换在 PS 侧统一处理一次。
- 来源：实测。模型在转置后的心尖朝上图像上训练，黄金集也是转置方向，所以 PASS 没有发现问题，最后靠真实数据 Dice 定位。

## 输入没有 flush / 输出没有 invalidate
关键词: flush, invalidate, 全部不同, 旧数据
- 现象：板上输出全零、等于上一次结果，或偶尔对偶尔错。仿真完全正确。
- 原因：`allocate` 的缓冲区经过 CPU 缓存；PL 直接读写 DDR。
- 确认：在 `--board fake` 下跑，fake_pynq 会报"写入后没有 flush()"。
- 修复：写完输入 `buf.flush()`，读输出前 `buf.invalidate()`（accel_driver.py 已经这样做）。
- 来源：通用。

## 内核不结束 / AXI 访问挂死整块板
关键词: ap_done 超时, BOARD_TIMEOUT, 超时, ap_idle=0
- 现象：脚本卡住，ssh 断开，板卡 ping 不通。
- 原因：访问了没有时钟/复位的 IP、地址越界，或内核在等永远不来的数据（流长度不对、TLAST 缺失）。
- 确认：`dump()` 打印的 ctrl：`0x1` = 已启动未完成；`0xffffffff` = 地址/时钟问题。
- 修复：每次板上运行都带 timeout（board.py 默认 120 s）；风险步骤之前先 `os.sync()`；断电重启后从 P4 冒烟开始查。
- 来源：实测（AXI 挂死导致整板冻结，之后所有板上命令都加了 timeout 和 sync）。

## 控制寄存器读到 0xFFFFFFFF
关键词: 0xffffffff, 时钟/复位
- 现象：冒烟在 registers 步骤失败。
- 原因：IP 不在这个地址上（hwh 与 bit 不匹配），或 PL 时钟 FCLK 没开、复位一直有效。
- 修复：重新拷贝同一次构建的 .bit/.hwh；Block Design 检查 `FCLK_CLK0` 和 `proc_sys_reset`；PYNQ 下可用 `pynq.Clocks.fclk0_mhz` 查看频率。
- 来源：通用。

## 寄存器偏移与 HLS 头文件不一致
关键词: 回读, 偏移, 不在 hwh 寄存器表
- 现象：寄存器回读不等于写入，或内核读到错误地址。
- 原因：偏移是推算出来的，不是从 `x*_hw.h` 抄的；改了函数参数后没有更新契约。
- 修复：照抄 `<solution>/impl/misc/drivers/*/src/x*_hw.h`；`check_build.py --contract` 会与 hwh 交叉检查。
- 来源：通用。

## 64 位地址只写了低 32 位
关键词: 高位, 64-bit, width
- 现象：Zynq-7000 上正常，换到 ZU+（DDR 地址 > 4 GB）后出错。
- 修复：契约里地址寄存器写 `width: 64`，驱动先写低字再写高字。
- 来源：通用。

## ip 名字不在 ip_dict
关键词: 不在 hwh, ip_dict, 没有实例
- 现象：`KeyError: ip 'xxx' 不在 hwh 中`。
- 原因：Block Design 里的实例名和契约不一致，或 IP 放在层次（hier）里，名字变成 `hier/xxx`。
- 修复：用报错里列出的名字更新 `contract.yaml` 的 `ip`。
- 来源：通用。

## Overlay 解析 hwh 失败
关键词: overlay, hwh, parse, xml
- 现象：`Overlay()` 抛出解析错误，但比特流本身没问题。
- 修复：确认 .hwh 与 .bit 同名且来自同一次构建；临时绕过可用 `pynq.Bitstream(bit).download()`，再手动设置 `Clocks.fclk0_mhz`，用 MMIO 访问已知地址。
- 来源：实测。

## DMA 报错或长度不对
关键词: slv_err, dec_err, int_err, halted, 从第
- 现象：DMASR 有错误位，或输出前一部分对、后面全错。
- 原因：DMA 的 Buffer Length Register 位宽不够（默认 14 位 = 16 KB）、发送长度和内核期望的不一致、TLAST 位置错误。
- 修复：AXI DMA 的 `Width of Buffer Length Register` 设为 23 或 26；收发长度都按契约 shape 计算。
- 来源：通用。

## import pynq 失败 / 权限不够
关键词: no module named, pynq_venv, permission denied, 需要 root
- 现象：普通 ssh 会话里 `import pynq` 失败，或 Overlay/allocate 报权限错误。
- 原因：PYNQ 的 Python 在 `/usr/local/share/pynq-venv`，需要 source 环境脚本；访问 PL 需要 root。
- 修复：用 `board.py run`（它会 source `xrt_setup.sh`、`boardname.sh`、`pynq_venv.sh`，并 sudo）。
- 来源：实测。

## 板上 pip/import 因 egg-info 损坏报错
关键词: urllib3, egg-info, metadata
- 现象：与本任务无关的包（如 urllib3）的元数据损坏，导致 import 或 pip 失败。
- 修复：不要在板上重装系统包；临时用 tmpfs 覆盖损坏的 egg-info 目录，或只用 venv 里已有的包。
- 来源：实测。

## sudo 需要密码导致 ssh 卡住或失败
关键词: password is required, a terminal is required, sudo
- 修复：在板上配置免密 sudo，或在 PC 设置环境变量 `PYNQ_SUDO_PASS`（board.py 通过 stdin 传递，不会出现在命令行里）。
- 来源：通用。

## ssh 连接失败
关键词: ssh 连接失败, connection refused, connection timed out, publickey, host key
- 修复：确认 IP 与网线；`ssh-copy-id xilinx@<ip>`；板卡重刷镜像后执行 `ssh-keygen -R <ip>` 清除旧主机密钥。board.py 用 BatchMode，不会弹出密码提示。
- 来源：通用。

## Windows 上 scp 把盘符当成主机名
关键词: could not resolve hostname d, could not resolve hostname c, program files/git
- 现象：`scp D:\proj\x.bit board:` 报"解析不了主机 D"；在 Git Bash/MSYS 下 `/home/xilinx` 被改写成 `C:/Program Files/Git/home/xilinx`。
- 修复：在项目根目录用相对路径（board.py 就是这样做的）；在 MSYS 下设置 `MSYS_NO_PATHCONV=1`。
- 来源：实测。

## 路径里有中文或空格
关键词: illegal character, non-ascii, 中文路径, unicode
- 现象：Vivado/HLS 打开工程或综合时报路径错误，Python 打开文件失败。
- 修复：工程放在纯 ASCII 路径下（例如 `D:/work/vadd`）。临时绕过可以拷贝到 ASCII 路径，或使用 Windows 短路径。
- 来源：实测。

## 工具输出中文乱码 / GBK 解码错误
关键词: gbk, unicodedecodeerror, codec can't decode
- 现象：中文 Windows 上，管道里的中文输出是乱码，或 `json.load` 抛出 `'gbk' codec can't decode`。
- 修复：读写文件一律写 `encoding="utf-8"`；子进程设置 `PYTHONUTF8=1`（gate.py 已经这样做）。
- 来源：实测（开发本技能包时出现）。

## 写 FIFO / 管道的命令在 ssh 里永久阻塞
关键词: fifo, 阻塞, hang
- 现象：`ssh board 'echo x > /tmp/some_fifo'` 永远不返回（另一端没有读者）。
- 修复：`timeout 2 sh -c 'echo x > /tmp/some_fifo'`；所有长命令都加 `timeout`。
- 来源：实测。

## DFX 部分比特流被静默忽略
关键词: fpga_manager, partial, .bin, byteswap
- 现象：通过 fpga_manager 加载部分重配置 `.bin` 没有报错，但 PL 行为没变。
- 修复：写入前做 32 位字节序交换；加载后读 RM 的 ID/版本寄存器确认。
- 来源：实测（仅 DFX 项目涉及）。

## 时序违例 / 资源过高
关键词: wns, whs, 利用率, 建立时间, 保持时间
- 现象：check_build 报 WNS < 0 或利用率 > 90%。
- 修复：降 PL 时钟；HLS 加 `PIPELINE`、切分长组合路径；资源紧张时降低并行度。DFX 项目里只是 RM 的问题，**不要改静态区/RP 边界**，否则静态区重新布局会引起拥塞（本项目曾因此出现 WNS -0.7 ns）。
- 来源：实测 + 通用。

## 先测瓶颈再优化
关键词: 加速比, 瓶颈, 优化
- 现象：PS 侧调优了很久，帧率不变。
- 原因：瓶颈在 PL（本项目解码器约 32 ms，所以上限约 30 fps），或者反过来，瓶颈在 PS 搬运和缓存刷新。
- 修复：看 perf_report 里"内核占端到端时间"的比例，只优化占比大的一侧。
- 来源：实测。

## fake 模式通过，真板失败
关键词: fake, pynq_fake
- 说明：fake_pynq 只验证驱动逻辑（寄存器映射、缓冲区连接、flush 调用、超时）。时序、缓存一致性、总线行为都必须在真板上验证；P6 会拒绝 fake 数据。
- 来源：通用。

## Windows 上 HLS csim 报 `/dev/null:1: *** missing separator`
关键词: missing separator, /dev/null, csim_design failed
- 现象：`csim_design` 编译失败，日志里只有 `/dev/null:1: *** missing separator.  Stop.`
- 原因：Windows 版 make 把 `/dev/null` 解析成当前盘的 `X:\dev\null`。如果这个文件真实存在（例如之前某个工具把日志写进了它），make 会把它当 makefile 读。
- 确认：`dir X:\dev\null`（X 为工程所在盘）。
- 修复：把该文件改名（不要直接删，先看内容）。工程放在没有 `\dev\null` 的盘上也可以。
- 注意：Vivado 每次运行都可能重新写出这个文件（内容是 `[Patcher] Current Virtual Memory Usage ...`），所以每次跑完 Vivado、再跑 HLS 之前都要检查一次；`templates/hls/run_hls.bat` 会在启动前自动删除这种 Patcher 日志。
- 来源：实测（PYNQ-Z2 vadd 与 axis_scale，Vitis HLS / Vivado 2024.2，同一问题出现了 3 次）。

## Windows 上 Vivado 报 `Could not create slave interpreter`
关键词: slave interpreter, Failed to deliver, IP Generation error, Failed to generate IP
- 现象：Block Design 能 validate，生成 IP（ps7、smartconnect 子核）时随机失败。
- 原因：从 git-bash/MSYS 启动 Vivado 会继承它的环境：PATH 里的 mingw `tcl86.dll`、`SHELL=/bin/bash.exe`、MSYS 风格的 HOME。
- 修复：用 `templates/hw/run_vivado.bat` 启动，它把 PATH/HOME/SHELL 重置成干净的 Windows 值。另外用 `axi_interconnect` 代替 `smartconnect`（子核少很多），`synth_checkpoint_mode None`，并对 `generate_target` 重试。
- 来源：实测（Vivado 2024.2）。

## 综合报 `illegal module recursion` / `parameter ... does not exist`
关键词: illegal module recursion, used as named parameter override
- 原因：Block Design 名字和 HLS 顶层函数同名（都叫 vadd），生成的模块重名。
- 修复：BD 取别的名字（模板里是 `<name>_bd`），输出时把 `.bit/.hwh` 复制成 `<name>.bit/.hwh`。
- 来源：实测。

## check_build 提示 hwh 没有寄存器表
关键词: hwh 没有该 IP 的寄存器表, ADDRESS_OFFSET
- 原因：Vivado 2024.2 的 hwh 里 `ADDRESS_OFFSET` 是十进制（`VALUE="16"` 即 0x10），早期版本的解析只认十六进制。现已同时支持两种。
- 来源：实测。

## 小内核上板反而比 CPU 慢
关键词: 加速比 < 1, 0.35x, flush 占比
- 现象：vadd（n=1024）端到端 1.07 ms，ARM 软件 0.37 ms；内核本身只占 12%。
- 原因：每次调用的 flush/invalidate 和 numpy 拷贝是固定开销，数据量小时盖过计算。
- 修复：这是正常现象，不是 bug。真实工程要么加大每次调用的数据量，要么让缓冲区常驻、只在必要时刷新。
- 来源：实测（PYNQ-Z2，pynq 3.1.1）。

## AXI DMA 传输卡住或只传了一部分
关键词: s2mm, mm2s, DMASR, dma 超时, TLAST, buffer length
- 现象：`recvchannel.wait()` / 驱动在 `axi_dma_0.s2mm` 上超时；或者大于 16 KB 的缓冲区只传了开头。
- 原因 1：流式内核没有在最后一拍置 TLAST。S2MM 只有收到 TLAST 才认为传输结束。
- 原因 2：AXI DMA 默认 `c_sg_length_width=14`，单次传输最多 16 KB-1，超过时被截断或报错。
- 确认：失败时驱动会打印 `mm2s_sr` / `s2mm_sr`；IDLE 不置位说明还在等数据（多半是 TLAST）。testbench 里检查 TLAST 只出现在第 n 拍。
- 修复：内核里 `o.last = (i == n - 1)`（不要只转发输入的 last）；Block Design 里设 `CONFIG.c_include_sg {0} CONFIG.c_sg_length_width {23}`。见 `templates/stream/`。
- 来源：实测模板（PYNQ-Z2 axis_scale，1024 点逐项一致）+ 通用（AXI DMA PG021）。

## HLS 综合报告里延迟是 `?`
关键词: Latency ?, latency=?, tripcount
- 原因：循环次数是运行时标量（例如 `n`），综合器不知道上界。不影响功能。
- 修复：要在报告里看到数字，就在循环里加 `#pragma HLS LOOP_TRIPCOUNT min=1 max=1024`（只影响报告）；或者直接以 P6 的实测时间为准。
- 来源：实测（axis_scale）。

## 跑完测试后板上原来的应用起不来（SIGBUS / external abort）
关键词: SIGBUS, status=7/BUS, external abort on non-linefetch, core-dump
- 现象：加载了自己的 overlay，测试通过，之后重启板上原有的服务时崩溃，dmesg 里有 `Unhandled fault: external abort`。
- 原因：`Overlay()` 加载的是整片 PL。原应用如果假设"PL 里已经是它的比特流"、在自己加载之前就访问外设地址，那些地址现在没人应答。
- 确认：`systemctl status <服务>`、`dmesg | tail`。
- 修复：测试前记下原应用的比特流和加载方式；测试后先把它的比特流加载回去（fpga_manager 或 `Overlay(原.bit)`），再按依赖顺序重启相关服务。不要在别人正在用的板子上测试而不恢复。
- 来源：实测（本项目 echo-demo + hand-sv：vadd 后能直接恢复，axis_scale 后必须先重载完整比特流）。

## 加速比接近 1：时间花在 Python 寄存器访问上
关键词: 加速比, speedup, MMIO, 1.0x, 驱动: python, accel_native
- 现象：内核本身很快（HLS 报告几十 us），但端到端 1~2 ms，加速比约 1x；报告头写着 `驱动: python`。
- 原因：PYNQ 的 `MMIO.read/write` 在 Zynq-7000 上每次约 15 us。一次 DMA 调用要 20 多次寄存器访问（复位、挂 S2MM/MM2S、ap_start、轮询），光这部分就有几百 us。
- 确认：`PYNQ_NATIVE=0` 与默认各跑一次 `board.py test` 对比 `kernel` 段。
- 修复：在 PC 上 `python skill/tools/cross_build.py`，通过后 `board.py push` 会把 `accel_native.so` 一起带上。不要在板上装编译器或编译。
- 来源：实测（A/B 实验 relu_q 剖析，PYNQ-Z2 pynq 3.1.1）。

## 交叉编译的 .so 在板上加载失败
关键词: GLIBC_2., version `GLIBC, cannot open shared object, wrong ELF class, accel_native.so, CROSS_BUILD_FAIL
- 现象：驱动打印 `accel_native.so 加载失败，退回 Python MMIO`，或报 `version GLIBC_2.3x not found` / `wrong ELF class`。
- 原因 1：交叉编译器的 sysroot glibc 比板上新（Vitis 2024.2 是 2.39，PYNQ 3.1 板上是 2.35），用到了新版本符号。
- 原因 2：编错了架构（aarch64 / 软浮点 gnueabi）。PYNQ-Z1/Z2 是 armv7 硬浮点。
- 原因 3：`/dev/mem` 需要 root；不用 sudo 跑时 `accel_run` 返回 -1。
- 确认：`board.py doctor` 打印板上 glibc；`cross_build.py --max-glibc 2.35` 会用 readelf 检查符号版本、ELF 类与 VFP 硬浮点标记。
- 修复：用 `cross_build.py`（固定 `-mfloat-abi=hard`），`--max-glibc` 设成板上版本；仍超出就避免用新函数（只用 open/mmap/clock_gettime 这类老接口）。随时可用 `PYNQ_NATIVE=0` 回退。
- 来源：实测（PYNQ-Z2 glibc 2.35 + Vitis 2024.2 工具链）。
