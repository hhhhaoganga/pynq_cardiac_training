# P1 黄金参考

目标：一个**按硬件方式计算**的 Python 模型，以及固定种子的测试向量 `data/golden/`。

## 要做
1. `mkdir golden && cp skill/templates/golden/*.py golden/`
2. 改 `golden/model.py`：
   - `make_inputs(params, rng)`：生成输入，dtype/shape 与契约一致。
   - `run(inputs, params)`：位宽、舍入、饱和、内存排布都要和硬件一样（int32 溢出就让它回绕，定点就先量化）。
3. 改 `golden/selftest.py` 里的 `independent_check`：用**另一种写法**再算一遍（循环版、查表版、scipy 版），防止模型本身写错。
4. 有真实数据的任务（图像、医学、语音）：在 `independent_check` 里加任务指标断言（准确率 / Dice / PSNR 阈值）。

## 关卡
`python golden/selftest.py` 打印 GATE_PASS，并生成 `data/golden/*.npy` 与 `*.bin`。

## 不要
- 不要拿 float 理想模型当硬件参考，P2 永远对不上。
- 黄金数据通过 ≠ 算法正确：方向/转置错了照样逐位一致（见 pitfalls「黄金 PASS 但真实数据全错」）。
