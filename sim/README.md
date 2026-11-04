# 仿真与验证结果

全部结果由 Vivado Simulator 2024.2（`xvlog` / `xelab` / `xsim`）实测产生，运行日期 2026-11-04。
逐用例的 elaborate 与运行日志在 `profile_rtl/<tb>/`、`knot/<case>/`，复现脚本在 `run/`。

## 1. 汇总

| 组 | 用例数 | 通过 |
|---|---|---|
| `profile_rtl/`（心腔分割 / 三维形状 RTL） | 36 | 36 |
| `knot/`（结型识别 SV） | 3 | 3 |

`profile_rtl` 的 36 个用例均为自包含 testbench，编译、elaborate、运行三段无错误，
每条在 `console.log` 末尾打印 `PASS`，日志与 `profile_rtl_src/` 中的源文件同批次产生。

## 2. profile_rtl：36 个通过的用例

```
camus_argmax_datamover_executor_tb         PASS pixels=15 cycles=27
camus_axi_ctrl_tb                          PASS status=00000003
camus_axi_stream_tile_bridge_tb            PASS beats=8
camus_compact_input_datamover_executor_tb  PASS pixels=31 cycles=45 stalls=13/3
camus_concat_job_rom_tb                    PASS stages=3
camus_concat_rescale_axis_tb               PASS dense_4_plus_4
camus_conv3x3_pe2_layer_tb                 PASS outputs=48            (3x3 PE2 scheduler)
camus_conv3x3_pe2_stream_tb                PASS groups=72 pixels=9    (shared PE2 layer2)
camus_conv_requant_relu_tb                 PASS outputs=2,0
camus_datamover_strip_executor_tb          PASS jobs=2 strips/job=3 beats=72 cycles=196
camus_enc12_chain_tb                       PASS outputs=8             (real enc1->enc1 layer2)
camus_enc12_pool_chain_tb                  PASS outputs=16
camus_enc12_pool_tile_tb                   PASS reads=16 checksum=246da0e2
camus_enc12_same_chain_tb                  PASS outputs=160 pixels=20
camus_enc3_stage_tb                        PASS outputs=256 pixels=16
camus_feature_repacker_tb                  PASS
camus_feature_tile_cache_tb                PASS tiles=1000 words=32000
camus_frame_op_rom_tb                      PASS ops=29 conv=19 aux=10
camus_frame_pipeline_controller_tb         PASS frames=6 cycles=157 overlap=70
camus_history_datamover_bridge_tb          PASS frames=3 strips=4 history_count=2 cycles=290
camus_layer_ctrl_tb                        PASS cycles=13
camus_layer_job_rom_tb                     PASS jobs=19 decoder=11
camus_lcc_datamover_executor_tb            PASS pixels=48 labels=6 cycles=449
camus_nearest_concat_datamover_executor_tb PASS 3 channel configurations
                                             case0 4+4   words=65536 cycles=156002
                                             case1 8+8   words=32768 cycles=57434
                                             case2 16+16 words=16384 cycles=28717
camus_output_axis_packer_pad_tb            PASS real=9 physical=18
camus_output_axis_packer_tb                PASS groups=101 beats=26 cycles=134
camus_pad2_stream_tb                       PASS outputs=48 pixels=6
camus_pad2_stream_256_tb                   PASS outputs=524288 pixels=65536 checksum=02479ed3
camus_pad2_stream_real_tb                  PASS beats=524288 pixels=65536
camus_phase_scheduler_tb                   PASS encoder_ops=11 decoder_ops=18
camus_pool_datamover_executor_tb           PASS words=4 cycles=28 input_stall=7 output_stall=0
camus_rescale_group_axis_tb                PASS groups=32 cycles=41
camus_stream_axi_ctrl_tb                   PASS status=00000008
camus_strip_descriptor_tb                  PASS 3x3_tiles=19 pointwise_tiles=4
camus_tile_pingpong_tb                     PASS bank_ready=10
camus_unet_pl_top_tb                       PASS full topology smoke
```

`camus_pad2_stream_real_tb` 使用真实 256×256 第一层 golden（524,288 beats / 65,536 像素），
`camus_pad2_stream_256_tb` 对同一尺寸做整幅校验（checksum `02479ed3`），两条构成端到端行为证据。

## 3. 固定期望值比对

36 条中有 3 条以固定期望值判定，断言位置如下：

| 用例 | 判定依据 |
|---|---|
| `camus_concat_job_rom_tb` | 期望值取自 `src/pl_rom_se_candidate/manifest.json` 的 `concat_stages`，与 `camus_concat_quant_desc.svh` 中 RTL 使用的 12 个常量逐一致；三个 stage 的倍率、移位、通道数与 tile 行数全部核对 |
| `camus_datamover_strip_executor_tb` | 2 个 job × 3 条带，逐 beat 计数（72）与周期数（196）固定，并检查 load/compute/output 三段的 overlap 与 stall |
| `camus_stream_axi_ctrl_tb` | 完整 AXI4-Lite 写读事务：配置 3 个寄存器 → 提交 → 回 result → 读 status / 结果 / 三类面积快照，submit 脉冲或任一寄存器值不符即 `$fatal` |

## 4. knot：3 个全部通过

| 用例 | 结果 |
|---|---|
| `knot`（RTL 全流程） | `BLOCK_PASS 0/1/2`，cycles 1,205,754 / 1,793,682 / 2,046,058 |
| `knotaxi`（AXI 通路） | `AXI_BLOCK_PASS 0/1/2`，cycles 1,227,654 / 1,833,965 / 2,093,091 |
| `quant`（量化边界） | `SV_QUANT_EDGE_PASS cases=512 lanes=4096` |

激励为 `knot_fixture/`（`memory.hex`、`golden.hex`、`program.json`、`program.txt`、`quant.txt`），
和板上 `board_app/data/nn/knot_sv/` 的部署权重同源。

## 5. 复现方式

```
cd sim
./run/run_one.sh camus_pad2_stream_real_tb     # 单条
./run/run_all.sh 40                            # 全部 36 条，40 路并行
./run/knot_sim.sh                              # knot 三条
```

三个脚本默认 Vivado 2024.2 装在 `~/Xilinx/Vivado/2024.2`，RTL 源在 `profile_rtl_src/`；
路径不同时用 `VIVADO` / `PROFILE_RTL` 环境变量覆盖。36 条在 `xargs -P 40` 下约 5 分钟跑完，
`run_all.sh` 的结果写入 `run/jobs/<tb>/{elaborate.log,console.log}`。

`profile_rtl_src/` 是 36 条用例所依赖的完整 RTL 与头文件（121 个 `.sv` / `.svh`），
与 `src/pl/profile_rtl/` 同源，单独放置以使 `sim/` 可以直接在未安装 Vivado 工程的机器上复跑。
