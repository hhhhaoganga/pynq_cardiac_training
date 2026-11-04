# 自己上板操作指南

这个板子不需要 Vivado 或 JTAG 烧写。位流和模型都是板上程序启动时自己加载的，"上板"就是三件事：用网线把文件拷到板上、在板上编译（只有改了代码才需要）、按顺序重启两个服务。

下面的命令都在 Windows PowerShell 里运行，一行一条，复制粘贴即可。要输密码时输入板子的登录密码（输入时屏幕上不显示字符，正常）。

## 0. 连通板子（每次先做）

1. 网线直连 PC 和板子，板子上电，等约 1 分钟启动完。
2. PC 的以太网口设固定 IP：「设置 → 网络 → 以太网 → IP 分配 → 编辑 → 手动」，IPv4 填 `169.254.1.100`，子网掩码 `255.255.0.0`，网关留空。现在这台 PC 已经设好了。
   不要用 `169.254.1.99` 和 `169.254.1.150`，这两个是板子自己的地址。
3. 测试：

```
ping 169.254.1.99
```

有回复就通了。

4. 登录板子（以后的板上命令都可以在这里敲，输入 `exit` 退出）：

```
ssh xilinx@169.254.1.99
```

第一次连会问 `Are you sure you want to continue connecting`，输入 `yes`。

## 1. 重启服务（最常用）

改了模型或程序后都要重启。**顺序不能反：先 hand-sv，等 25 秒，再 echo-demo。**只重启 echo-demo 会让手部关键点报错（日志刷 "Hand backend fault latched"），遇到了就按这个顺序重来一遍。

```
ssh -t xilinx@169.254.1.99 "sudo systemctl restart hand-sv"
```

```
Start-Sleep -Seconds 25
```

```
ssh -t xilinx@169.254.1.99 "sudo systemctl restart echo-demo"
```

检查两个服务都是 `active`：

```
ssh xilinx@169.254.1.99 "systemctl is-active hand-sv echo-demo"
```

看最近的日志（有没有报错）：

```
ssh -t xilinx@169.254.1.99 "sudo journalctl -u echo-demo -n 40 --no-pager"
```

## 2. 换结型分类器（重训后上板）

假设新文件在 `D:\PLD\new_cls\` 里，有 `knot_cls.nnp`、`knot_cls_in.u8`、`knot_cls_out.f32` 三个。

1. 在板上建暂存目录：

```
ssh xilinx@169.254.1.99 "mkdir -p ~/knot_cls_new/golden_knot_cls"
```

2. 拷文件上去：

```
scp D:\PLD\new_cls\knot_cls.nnp xilinx@169.254.1.99:knot_cls_new/
```

```
scp D:\PLD\new_cls\knot_cls_in.u8 D:\PLD\new_cls\knot_cls_out.f32 xilinx@169.254.1.99:knot_cls_new/golden_knot_cls/
```

3. 先在暂存目录校验，最后一行必须是 `KNOT_CLS_CHECK_PASS`，不是就停下别换：

```
ssh xilinx@169.254.1.99 "~/hand_pipeline_v3_20261010/app_ecg/build/knot_cls_check ~/knot_cls_new"
```

如果提示找不到 `knot_cls_check`（整版恢复后 `build/` 目录是空的），先在板上编一次这个检查程序：

```
ssh xilinx@169.254.1.99 "cd ~/hand_pipeline_v3_20261010/app_ecg; mkdir -p build; g++ -O2 -std=c++17 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ftree-vectorize -ffast-math -Isrc -I/usr/include/xrt knot_cls_check.cpp src/nn.cpp src/hw.cpp -lxrt_coreutil -lpthread -o build/knot_cls_check"
```

4. 备份旧的（把日期改成当天，别和已有的重名）：

```
ssh xilinx@169.254.1.99 "cd ~/board_app/data/nn; cp knot_cls.nnp knot_cls_old_1101.nnp; cp -r golden_knot_cls golden_knot_cls_old_1101"
```

5. 换上新的：

```
ssh xilinx@169.254.1.99 "cp ~/knot_cls_new/knot_cls.nnp ~/board_app/data/nn/; cp ~/knot_cls_new/golden_knot_cls/* ~/board_app/data/nn/golden_knot_cls/"
```

6. 按第 1 节重启。只换分类器其实只重启 echo-demo 也行，但按完整顺序最保险。

回退：把第 4 步的备份拷回去，再重启。

## 3. 改了板端代码（例如界面 ui.cpp）

源码在本包 `source\app_ecg_train\src\`，板上对应 `~/hand_pipeline_v3_20261010/app_ecg/src/`。

1. 备份板上的程序和源码（日期改成当天）：

```
ssh xilinx@169.254.1.99 "cd ~/hand_pipeline_v3_20261010/app_ecg; cp -r src src_bak_1101; cp echo_demo echo_demo.bak_1101"
```

2. 拷改过的文件上去（例子是 ui.cpp，改了几个就拷几个）：

```
scp D:\PLD\final1029\source\app_ecg_train\src\ui.cpp xilinx@169.254.1.99:hand_pipeline_v3_20261010/app_ecg/src/
```

3. 在板上编译。只改 .cpp 约 3 分钟；改了 .hpp 头文件要先清掉旧的中间文件，约 10 分钟：

```
ssh xilinx@169.254.1.99 "cd ~/hand_pipeline_v3_20261010/app_ecg; make -j2"
```

改了头文件时改用这条：

```
ssh xilinx@169.254.1.99 "cd ~/hand_pipeline_v3_20261010/app_ecg; rm -f build/*.o; make -j2"
```

最后没有 `error` 就是编好了。有 error 时板上还是旧程序，不影响使用，改好代码再编。

4. 按第 1 节重启，然后看 HDMI 屏幕确认。

5. 门禁（改了程序建议跑）：先在 HDMI 界面点到「① 心腔分割」页，再运行：

```
ssh xilinx@169.254.1.99 "cd ~/board_app; python3 tools/proto_check.py"
```

```
ssh -t xilinx@169.254.1.99 "cd ~/board_app; sudo python3 tools/ui_mouse_check.py"
```

最后一行分别是 `PROTO_CHECK_PASS`、`UI_MOUSE_CHECK_PASS` 就对了。`demo_toggle_check.sh` 现在必然 FAIL，不用跑（原因见 handoff.md 第 5 节）。

回退：

```
ssh xilinx@169.254.1.99 "cd ~/hand_pipeline_v3_20261010/app_ecg; cp echo_demo.bak_1101 echo_demo; rm -rf src; cp -r src_bak_1101 src"
```

再按第 1 节重启。

## 4. 整版恢复成 final1029（板子被改乱了，或换了一块板）

一条命令把板上整套程序、模型、服务配置恢复成本包的版本。板上原有的目录会先改名备份，不会删。中途会问几次密码。

```
& "C:\Program Files\Git\bin\bash.exe" D:/PLD/final1029/restore_board.sh 169.254.1.99
```

注意这条命令里的路径要用正斜杠 `/`。跑完最后会显示 `active active`。

## 5. 全新 SD 卡从零开始

1. 下载官方 PYNQ-Z2 v3.1 镜像，用 balenaEtcher 写到 SD 卡（16 GB 以上）。
2. 板子拨码开关拨到 SD 启动，插卡上电。
3. 按第 0 节连通，然后按第 4 节整版恢复。

说明：第 4 节的脚本在已经跑过本项目的板子上用过。全新镜像上是否还缺系统依赖（例如 XRT 库）我没有实测，第一次在新卡上做时请留意报错。

## 常见问题

| 现象 | 处理 |
|---|---|
| `ping` 不通 | 检查网线、板子电源指示灯；PC 以太网 IP 是否为 169.254.1.100 / 255.255.0.0 |
| ssh 报 `REMOTE HOST IDENTIFICATION HAS CHANGED` | 换过 SD 卡后正常。运行 `ssh-keygen -R 169.254.1.99` 再连 |
| 手部关键点 / 打结训练页不出结果 | 按第 1 节顺序重启两个服务 |
| 屏幕黑屏或界面没出来 | 看第 1 节的日志命令；不行就回退到上一个备份 |
| 不确定板上现在是哪个版本 | `ssh xilinx@169.254.1.99 "sha256sum ~/hand_pipeline_v3_20261010/app_ecg/echo_demo"`，和 handoff.md 开头写的 sha 对比 |
