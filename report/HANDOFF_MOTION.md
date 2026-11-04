# E-PiVox 心动播放 交接说明

## 功能
E-PiVox（K16 形状重建）页面里，重建出的舒张末 (ED) 心脏网格会按收缩运动模型跳动，**PL 不改动**。
- 运动场：`dS = mbase + Σ code_k·mbasis_k`，由 16 个 K16 形状系数线性预测。
- 相位：`sdf(w) = sdf_ED + w·dS`，w=0 是 ED，w=1 是 ES，共 7 个相位网格。
- 节律：接上心电时，按 R 波触发（`beat_curve`，收缩占 RR 的 35%，85% 处回到舒张）；没接心电时，按模拟 60 次/分 播放。
- 播放周期跟心率成反比：周期 = 60/bpm，收缩期和舒张期同比例缩放。真实心脏在心率高时主要是舒张期变短，后续可以改成收缩期固定约 300 ms、舒张期吃掉剩下的时间。
- 界面已标注“收缩运动为通用生理模型 (由形状系数预测)，非该病例实测”。

## 运动模型（离线，服务器 GPU）
- 脚本在 `beat_motion/`：
  - `beat_v2.py` / `gen_all.py`：生成 1000 例合成 ED/ES；
  - `fit_motion.py`：拟合系数 → 运动的回归；
  - `export_motion.py`：导出板端文件；
  - `validate.py`：验证。
  - `dbg_*`、`probe_*` 是调试脚本，可以删。
- 服务器 python 用 `/home/lizx/.conda/envs/heart25d/bin/python`。系统自带的 python3 没有 numpy。
- 导出命令：`export_motion.py --fit motion_fit_k16.npz --gen gen_v2 --board-tools . --out board_export`
- 指标：

  | 项目 | 结果 |
  |---|---|
  | 150 例 ES Dice（板端算法 vs 生成真值） | 0.967（最低 0.909） |
  | 重建上限 | 0.969 |
  | int16 量化误差 | 0.0003 mm |

## 板端文件
- `shape_motion.bin`：格式 `"EMOT" | u32 res | u32 K | f32 scale[K+1] | i16 mbase | i16 mbasis[K]`，8.9 MB。
- `motion_reference.txt`：`--bench-shape` 自检用的参考数据。
- 这两个文件放在 `/home/xilinx/board_app/data/`。文件不存在时，功能自动关闭，回到原来的静态显示。

## 代码改动（`app_ecg/src`）
- `shape_model.*`：新增 `load_motion`、`motion`、`blend`。
- `worker.*`：
  - 先回包、发布 ED 网格；
  - 再用 `step_motion()` 在空闲时一步一步建相位，每步约 50 ms，共 7 步；
  - 有新任务排队时让路，所以连续的形状请求不会被拖慢；
  - 用 `frame_id` 防止旧病例的相位覆盖新病例。
- `ui.*`：
  - `update_px_beat` 选相位，相位变化时才调用 `set_mesh`；
  - `beat_curve` 和双平面模式共用。
- `demo.*`：有运动文件时，每个形状病例停留 4 s（共 6 例）。
- `main.cpp`：
  - 启动时加载运动文件；
  - `--bench-shape` 增加运动自检。
- `i18n.cpp`：新增的界面文字。

## 板上现状
- 源码和二进制：`/home/xilinx/hand_pipeline_v3_20261010/app_ecg/`，服务 `echo-demo` 已在运行新版。
- 改动前的备份：`/home/xilinx/hand_pipeline_v3_20261010/app_ecg_pre_motion/`。想回退，用备份目录的 `echo_demo` 替换后重启服务即可。

## 已验证
| 项目 | 结果 |
|---|---|
| `--bench-shape` 运动自检 | 20 例 ES 体素最大偏差 1，PASS；运动场 50 ms，每相位 blend+extract 49 ms |
| `proto_check.py` | PASS：shape 150 例 0 误差，15.3 s；seg 30 fps |
| `ui_mouse_check.py` | 第一版 PASS。改成空闲分步之后又跑了一次，交接时还没出结果 |
| `demo_toggle_check.sh` | FAIL。服务用的是 `--no-demo`，原版本也一样失败，不是这次改出来的 |

## 注意
- 板上 `make -j2` 全量编译约 10 分钟。建议在服务器上用 docker 起 Ubuntu 22.04，装 `g++-arm-linux-gnueabihf`（gcc 11），sysroot 从板子同步，做交叉编译。
- AD8232 心电模块没有隔离，不能接人体做临床用途，仅限演示。
