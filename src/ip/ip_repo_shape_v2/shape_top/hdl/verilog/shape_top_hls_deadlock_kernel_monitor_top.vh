
wire kernel_monitor_reset;
wire kernel_monitor_clock;
wire kernel_monitor_report;
assign kernel_monitor_reset = ~ap_rst_n;
assign kernel_monitor_clock = ap_clk;
assign kernel_monitor_report = 1'b0;
wire [1:0] axis_block_sigs;
wire [15:0] inst_idle_sigs;
wire [11:0] inst_block_sigs;
wire kernel_block;

assign axis_block_sigs[0] = ~read_input_U0.input_r_TDATA_blk_n;
assign axis_block_sigs[1] = ~write_output_U0.grp_write_output_Pipeline_VITIS_LOOP_205_1_fu_44.output_r_TDATA_blk_n;

assign inst_idle_sigs[0] = read_input_U0.ap_idle;
assign inst_block_sigs[0] = (read_input_U0.ap_done & ~read_input_U0.ap_continue) | ~read_input_U0.px0_blk_n;
assign inst_idle_sigs[1] = window_1_224_224_U0.ap_idle;
assign inst_block_sigs[1] = (window_1_224_224_U0.ap_done & ~window_1_224_224_U0.ap_continue) | ~window_1_224_224_U0.px0_blk_n | ~window_1_224_224_U0.win1_blk_n;
assign inst_idle_sigs[2] = compute_0_1_8_9_25088_U0.ap_idle;
assign inst_block_sigs[2] = (compute_0_1_8_9_25088_U0.ap_done & ~compute_0_1_8_9_25088_U0.ap_continue) | ~compute_0_1_8_9_25088_U0.win1_blk_n | ~compute_0_1_8_9_25088_U0.px1_blk_n;
assign inst_idle_sigs[3] = window_8_112_112_U0.ap_idle;
assign inst_block_sigs[3] = (window_8_112_112_U0.ap_done & ~window_8_112_112_U0.ap_continue) | ~window_8_112_112_U0.px1_blk_n | ~window_8_112_112_U0.win2_blk_n;
assign inst_idle_sigs[4] = compute_1_8_16_36_6272_U0.ap_idle;
assign inst_block_sigs[4] = (compute_1_8_16_36_6272_U0.ap_done & ~compute_1_8_16_36_6272_U0.ap_continue) | ~compute_1_8_16_36_6272_U0.win2_blk_n | ~compute_1_8_16_36_6272_U0.px2_blk_n;
assign inst_idle_sigs[5] = window_16_56_56_U0.ap_idle;
assign inst_block_sigs[5] = (window_16_56_56_U0.ap_done & ~window_16_56_56_U0.ap_continue) | ~window_16_56_56_U0.px2_blk_n | ~window_16_56_56_U0.win3_blk_n;
assign inst_idle_sigs[6] = compute_2_16_24_36_1568_U0.ap_idle;
assign inst_block_sigs[6] = (compute_2_16_24_36_1568_U0.ap_done & ~compute_2_16_24_36_1568_U0.ap_continue) | ~compute_2_16_24_36_1568_U0.win3_blk_n | ~compute_2_16_24_36_1568_U0.px3_blk_n;
assign inst_idle_sigs[7] = window_24_28_28_U0.ap_idle;
assign inst_block_sigs[7] = (window_24_28_28_U0.ap_done & ~window_24_28_28_U0.ap_continue) | ~window_24_28_28_U0.px3_blk_n | ~window_24_28_28_U0.win4_blk_n;
assign inst_idle_sigs[8] = compute_3_24_32_18_392_U0.ap_idle;
assign inst_block_sigs[8] = (compute_3_24_32_18_392_U0.ap_done & ~compute_3_24_32_18_392_U0.ap_continue) | ~compute_3_24_32_18_392_U0.win4_blk_n | ~compute_3_24_32_18_392_U0.px4_blk_n;
assign inst_idle_sigs[9] = pool_U0.ap_idle;
assign inst_block_sigs[9] = (pool_U0.ap_done & ~pool_U0.ap_continue) | ~pool_U0.grp_pool_Pipeline_VITIS_LOOP_136_2_fu_46.px4_blk_n | ~pool_U0.grp_pool_Pipeline_VITIS_LOOP_140_3_VITIS_LOOP_141_4_VITIS_LOOP_142_5_VITIS_LOOP_145_s_fu_53.feat_blk_n;
assign inst_idle_sigs[10] = fc_U0.ap_idle;
assign inst_block_sigs[10] = (fc_U0.ap_done & ~fc_U0.ap_continue) | ~fc_U0.grp_fc_Pipeline_VITIS_LOOP_188_1_fu_247.feat_blk_n | ~fc_U0.coef_blk_n;
assign inst_idle_sigs[11] = write_output_U0.ap_idle;
assign inst_block_sigs[11] = (write_output_U0.ap_done & ~write_output_U0.ap_continue) | ~write_output_U0.coef_blk_n;

assign inst_idle_sigs[12] = 1'b0;
assign inst_idle_sigs[13] = read_input_U0.ap_idle;
assign inst_idle_sigs[14] = write_output_U0.ap_idle;
assign inst_idle_sigs[15] = write_output_U0.grp_write_output_Pipeline_VITIS_LOOP_205_1_fu_44.ap_idle;

shape_top_hls_deadlock_idx0_monitor shape_top_hls_deadlock_idx0_monitor_U (
    .clock(kernel_monitor_clock),
    .reset(kernel_monitor_reset),
    .axis_block_sigs(axis_block_sigs),
    .inst_idle_sigs(inst_idle_sigs),
    .inst_block_sigs(inst_block_sigs),
    .block(kernel_block)
);


always @ (kernel_block or kernel_monitor_reset) begin
    if (kernel_block == 1'b1 && kernel_monitor_reset == 1'b0) begin
        find_kernel_block = 1'b1;
    end
    else begin
        find_kernel_block = 1'b0;
    end
end
