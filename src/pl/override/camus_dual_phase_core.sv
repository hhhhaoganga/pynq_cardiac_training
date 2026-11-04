`timescale 1ns/1ps

// Complete fixed graph core with independent encoder and decoder DMA ports.
// Adjacent frames use separate DDR buffer slots supplied by the outer control
// plane; both phases share only the causal three-bank bottleneck history.
module camus_dual_phase_core (
    input logic clk,input logic rst,input logic clear_history,
    input logic enc_start,input logic dec_start,input logic post_start,
    input logic [31:0] post_logits_base,input logic [31:0] post_mask_base,
    input logic [31:0] enc_input_base,input logic [31:0] enc_skip_base,
    input logic [31:0] enc_scratch_base,
    input logic [31:0] dec_mask_base,input logic [31:0] dec_skip_base,
    input logic [31:0] dec_scratch_base,input logic [31:0] watchdog_limit,

    output logic enc_mm2s_cmd_valid,input logic enc_mm2s_cmd_ready,
    output logic [71:0] enc_mm2s_cmd_data,
    input logic enc_mm2s_sts_valid,output logic enc_mm2s_sts_ready,
    input logic [7:0] enc_mm2s_sts_data,
    input logic enc_mm2s_valid,output logic enc_mm2s_ready,
    input logic [127:0] enc_mm2s_data,input logic [15:0] enc_mm2s_keep,
    input logic enc_mm2s_last,
    output logic enc_s2mm_cmd_valid,input logic enc_s2mm_cmd_ready,
    output logic [71:0] enc_s2mm_cmd_data,
    input logic enc_s2mm_sts_valid,output logic enc_s2mm_sts_ready,
    input logic [7:0] enc_s2mm_sts_data,
    output logic enc_s2mm_valid,input logic enc_s2mm_ready,
    output logic [127:0] enc_s2mm_data,output logic [15:0] enc_s2mm_keep,
    output logic enc_s2mm_last,

    output logic dec_mm2s_cmd_valid,input logic dec_mm2s_cmd_ready,
    output logic [71:0] dec_mm2s_cmd_data,
    input logic dec_mm2s_sts_valid,output logic dec_mm2s_sts_ready,
    input logic [7:0] dec_mm2s_sts_data,
    input logic dec_mm2s_valid,output logic dec_mm2s_ready,
    input logic [127:0] dec_mm2s_data,input logic [15:0] dec_mm2s_keep,
    input logic dec_mm2s_last,
    output logic dec_s2mm_cmd_valid,input logic dec_s2mm_cmd_ready,
    output logic [71:0] dec_s2mm_cmd_data,
    input logic dec_s2mm_sts_valid,output logic dec_s2mm_sts_ready,
    input logic [7:0] dec_s2mm_sts_data,
    output logic dec_s2mm_valid,input logic dec_s2mm_ready,
    output logic [127:0] dec_s2mm_data,output logic [15:0] dec_s2mm_keep,
    output logic dec_s2mm_last,

    output logic post_mm2s_cmd_valid,input logic post_mm2s_cmd_ready,
    output logic [71:0] post_mm2s_cmd_data,
    input logic post_mm2s_sts_valid,output logic post_mm2s_sts_ready,
    input logic [7:0] post_mm2s_sts_data,
    input logic post_mm2s_valid,output logic post_mm2s_ready,
    input logic [127:0] post_mm2s_data,input logic [15:0] post_mm2s_keep,
    input logic post_mm2s_last,
    output logic post_s2mm_cmd_valid,input logic post_s2mm_cmd_ready,
    output logic [71:0] post_s2mm_cmd_data,
    input logic post_s2mm_sts_valid,output logic post_s2mm_sts_ready,
    input logic [7:0] post_s2mm_sts_data,
    output logic post_s2mm_valid,input logic post_s2mm_ready,
    output logic [127:0] post_s2mm_data,output logic [15:0] post_s2mm_keep,
    output logic post_s2mm_last,
    output logic post_busy,output logic post_done,output logic post_error,
    output logic [63:0] post_cycle_count,output logic [4:0] post_current_op,

    output logic enc_busy,output logic enc_done,output logic enc_error,
    output logic [63:0] enc_cycle_count,output logic [4:0] enc_current_op,
    output logic dec_busy,output logic dec_done,output logic dec_error,
    output logic [63:0] dec_cycle_count,output logic [4:0] dec_current_op,
    output logic [1:0] history_count,output logic history_busy,
    output logic history_error,
    output logic [50:0] area_counts,
    input logic profile_rearm, input logic profile_pack_busy,
    input logic [7:0] profile_read_index,
    output logic [31:0] profile_read_data
);
    logic [4:0] enc_current_op_raw,dec_lcc_debug_wait;
    logic h_enc_cmd_valid,h_enc_cmd_ready,h_enc_status_valid,h_enc_status_ready;
    logic [71:0] h_enc_cmd_data;
    logic [7:0] h_enc_status_data;
    logic h_enc_data_valid,h_enc_data_ready,h_enc_last;
    logic [127:0] h_enc_data;
    logic [15:0] h_enc_keep;
    logic h_dec_cmd_valid,h_dec_cmd_ready,h_dec_status_valid,h_dec_status_ready;
    logic [71:0] h_dec_cmd_data;
    logic [7:0] h_dec_status_data;
    logic h_dec_data_valid,h_dec_data_ready,h_dec_last;
    logic [127:0] h_dec_data;
    logic [15:0] h_dec_keep;
    logic profile_op_start, profile_op_done;
    logic [4:0] profile_op_index;
    logic [127:0] profile_conv_metrics;
    logic [2:0] profile_token_events;
    logic post_op_start,post_op_done;
    logic [4:0] post_op_index;
    logic [31:0] network_profile_data,post_profile_data;
    logic [7:0] post_profile_index;
    assign post_profile_index=profile_read_index>=16 && profile_read_index<32
        ? profile_read_index-8'd16 : profile_read_index;
    assign profile_read_data=profile_read_index==0 ? 32'h50524632
        : ((profile_read_index>=16 && profile_read_index<32)
            || (profile_read_index>=208 && profile_read_index<224))
        ? post_profile_data : network_profile_data;

    // pynq_dfx override: the PRF2 performance monitors only feed the old
    // FreeRTOS UART profile dump (profile_read_index/_data); nothing in the
    // datapath or control flow uses them. They cost ~480 slices, so they are
    // disabled for the DFX slot. Index 0 still returns the PRF2 signature;
    // every other profile word reads 0. Set ENABLE_PROFILE=1 to restore.
    localparam bit ENABLE_PROFILE = 1'b0;
    generate
        if (ENABLE_PROFILE) begin : g_profile
            camus_performance_monitor #(.LAST_OP(26)) u_profile (
                .clk, .rst, .rearm(profile_rearm), .dec_start, .dec_done,
                .enc_busy, .dec_busy, .pack_busy(profile_pack_busy),
                .history_reset(clear_history),
                .core_error(enc_error || dec_error || history_error),
                .op_start(profile_op_start), .op_done(profile_op_done),
                .op_index(profile_op_index), .conv_metrics(profile_conv_metrics),
                .token_events(profile_token_events), .read_index(profile_read_index),
                .read_data(network_profile_data)
            );
            camus_performance_monitor #(.FIRST_OP(27),.LAST_OP(28)) u_post_profile (
                .clk,.rst,.rearm(profile_rearm),.dec_start(post_start),.dec_done(post_done),
                .enc_busy(dec_busy),.dec_busy(post_busy),.pack_busy(enc_busy),
                .history_reset(clear_history),.core_error(post_error),
                .op_start(post_op_start),.op_done(post_op_done),.op_index(post_op_index),
                .conv_metrics(128'd0),.token_events(3'd0),
                .read_index(post_profile_index),.read_data(post_profile_data));
        end else begin : g_no_profile
            assign network_profile_data = 32'd0;
            assign post_profile_data = 32'd0;
        end
    endgenerate

    // A queued decoder must consume its temporal tensor before the next
    // encoder rotates history, including when the post ring applies backpressure.
    logic history_pending, history_write_ready;
    assign h_enc_cmd_ready = history_write_ready && !history_pending;
    always_ff @(posedge clk) begin
        if (rst || clear_history) history_pending <= 0;
        else begin
            if (h_enc_cmd_valid && h_enc_cmd_ready) history_pending <= 1;
            if (profile_op_done && profile_op_index == 12) history_pending <= 0;
        end
    end
    camus_history_datamover_bridge #(.FIXED_TEMPORAL_STRIPS(1'b1)) u_history (
        .clk,.rst,.clear_history,
        .enc_cmd_valid(h_enc_cmd_valid && !history_pending),.enc_cmd_ready(history_write_ready),
        .enc_cmd_data(h_enc_cmd_data),.enc_status_valid(h_enc_status_valid),
        .enc_status_ready(h_enc_status_ready),.enc_status_data(h_enc_status_data),
        .enc_data_valid(h_enc_data_valid),.enc_data_ready(h_enc_data_ready),
        .enc_data(h_enc_data),.enc_keep(h_enc_keep),.enc_last(h_enc_last),
        .dec_cmd_valid(h_dec_cmd_valid),.dec_cmd_ready(h_dec_cmd_ready),
        .dec_cmd_data(h_dec_cmd_data),.dec_status_valid(h_dec_status_valid),
        .dec_status_ready(h_dec_status_ready),.dec_status_data(h_dec_status_data),
        .dec_data_valid(h_dec_data_valid),.dec_data_ready(h_dec_data_ready),
        .dec_data(h_dec_data),.dec_keep(h_dec_keep),.dec_last(h_dec_last),
        .history_count,.busy(history_busy),.error(history_error));

    camus_encoder_phase_executor u_encoder (
        .clk,.rst,.start(enc_start),.input_base(enc_input_base),
        .mask_base(32'd0),.skip_base(enc_skip_base),
        .scratch_base(enc_scratch_base),.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(enc_mm2s_cmd_valid),
        .m_axis_mm2s_cmd_tready(enc_mm2s_cmd_ready),
        .m_axis_mm2s_cmd_tdata(enc_mm2s_cmd_data),
        .s_axis_mm2s_sts_tvalid(enc_mm2s_sts_valid),
        .s_axis_mm2s_sts_tready(enc_mm2s_sts_ready),
        .s_axis_mm2s_sts_tdata(enc_mm2s_sts_data),
        .s_axis_mm2s_tvalid(enc_mm2s_valid),.s_axis_mm2s_tready(enc_mm2s_ready),
        .s_axis_mm2s_tdata(enc_mm2s_data),.s_axis_mm2s_tkeep(enc_mm2s_keep),
        .s_axis_mm2s_tlast(enc_mm2s_last),
        .m_axis_s2mm_cmd_tvalid(enc_s2mm_cmd_valid),
        .m_axis_s2mm_cmd_tready(enc_s2mm_cmd_ready),
        .m_axis_s2mm_cmd_tdata(enc_s2mm_cmd_data),
        .s_axis_s2mm_sts_tvalid(enc_s2mm_sts_valid),
        .s_axis_s2mm_sts_tready(enc_s2mm_sts_ready),
        .s_axis_s2mm_sts_tdata(enc_s2mm_sts_data),
        .m_axis_s2mm_tvalid(enc_s2mm_valid),.m_axis_s2mm_tready(enc_s2mm_ready),
        .m_axis_s2mm_tdata(enc_s2mm_data),.m_axis_s2mm_tkeep(enc_s2mm_keep),
        .m_axis_s2mm_tlast(enc_s2mm_last),
        .hist_cmd_valid(h_enc_cmd_valid),.hist_cmd_ready(h_enc_cmd_ready),
        .hist_cmd_data(h_enc_cmd_data),.hist_status_valid(h_enc_status_valid),
        .hist_status_ready(h_enc_status_ready),.hist_status_data(h_enc_status_data),
        .hist_data_valid(h_enc_data_valid),.hist_data_ready(h_enc_data_ready),
        .hist_data(h_enc_data),.hist_keep(h_enc_keep),.hist_last(h_enc_last),
        .busy(enc_busy),.done(enc_done),.error(enc_error),
        .cycle_count(enc_cycle_count),.current_op(enc_current_op_raw));

    camus_decoder_phase_executor #(.LAST_OP(26)) u_decoder (
        .clk,.rst,.start(dec_start),.input_base(32'd0),.mask_base(dec_mask_base),
        .skip_base(dec_skip_base),.scratch_base(dec_scratch_base),
        .watchdog_limit,.history_available(history_count!=0),
        .m_axis_mm2s_cmd_tvalid(dec_mm2s_cmd_valid),
        .m_axis_mm2s_cmd_tready(dec_mm2s_cmd_ready),
        .m_axis_mm2s_cmd_tdata(dec_mm2s_cmd_data),
        .s_axis_mm2s_sts_tvalid(dec_mm2s_sts_valid),
        .s_axis_mm2s_sts_tready(dec_mm2s_sts_ready),
        .s_axis_mm2s_sts_tdata(dec_mm2s_sts_data),
        .s_axis_mm2s_tvalid(dec_mm2s_valid),.s_axis_mm2s_tready(dec_mm2s_ready),
        .s_axis_mm2s_tdata(dec_mm2s_data),.s_axis_mm2s_tkeep(dec_mm2s_keep),
        .s_axis_mm2s_tlast(dec_mm2s_last),
        .m_axis_s2mm_cmd_tvalid(dec_s2mm_cmd_valid),
        .m_axis_s2mm_cmd_tready(dec_s2mm_cmd_ready),
        .m_axis_s2mm_cmd_tdata(dec_s2mm_cmd_data),
        .s_axis_s2mm_sts_tvalid(dec_s2mm_sts_valid),
        .s_axis_s2mm_sts_tready(dec_s2mm_sts_ready),
        .s_axis_s2mm_sts_tdata(dec_s2mm_sts_data),
        .m_axis_s2mm_tvalid(dec_s2mm_valid),.m_axis_s2mm_tready(dec_s2mm_ready),
        .m_axis_s2mm_tdata(dec_s2mm_data),.m_axis_s2mm_tkeep(dec_s2mm_keep),
        .m_axis_s2mm_tlast(dec_s2mm_last),
        .hist_cmd_valid(h_dec_cmd_valid),.hist_cmd_ready(h_dec_cmd_ready),
        .hist_cmd_data(h_dec_cmd_data),.hist_status_valid(h_dec_status_valid),
        .hist_status_ready(h_dec_status_ready),.hist_status_data(h_dec_status_data),
        .hist_data_valid(h_dec_data_valid),.hist_data_ready(h_dec_data_ready),
        .hist_data(h_dec_data),.hist_keep(h_dec_keep),.hist_last(h_dec_last),
        .busy(dec_busy),.done(dec_done),.error(dec_error),
        .cycle_count(dec_cycle_count),.current_op(dec_current_op),
        .lcc_debug_wait(),.area_counts(),
        .profile_op_start, .profile_op_done, .profile_op_index,
        .profile_conv_metrics, .profile_token_events);

    camus_decoder_phase_executor #(.FIRST_OP(27),.LAST_OP(28)) u_postprocessor (
        .clk,.rst,.start(post_start),.input_base(32'd0),.mask_base(post_mask_base),
        .skip_base(32'd0),.scratch_base(post_logits_base),
        .watchdog_limit,.history_available(1'b1),
        .m_axis_mm2s_cmd_tvalid(post_mm2s_cmd_valid),
        .m_axis_mm2s_cmd_tready(post_mm2s_cmd_ready),
        .m_axis_mm2s_cmd_tdata(post_mm2s_cmd_data),
        .s_axis_mm2s_sts_tvalid(post_mm2s_sts_valid),
        .s_axis_mm2s_sts_tready(post_mm2s_sts_ready),
        .s_axis_mm2s_sts_tdata(post_mm2s_sts_data),
        .s_axis_mm2s_tvalid(post_mm2s_valid),.s_axis_mm2s_tready(post_mm2s_ready),
        .s_axis_mm2s_tdata(post_mm2s_data),.s_axis_mm2s_tkeep(post_mm2s_keep),
        .s_axis_mm2s_tlast(post_mm2s_last),
        .m_axis_s2mm_cmd_tvalid(post_s2mm_cmd_valid),
        .m_axis_s2mm_cmd_tready(post_s2mm_cmd_ready),
        .m_axis_s2mm_cmd_tdata(post_s2mm_cmd_data),
        .s_axis_s2mm_sts_tvalid(post_s2mm_sts_valid),
        .s_axis_s2mm_sts_tready(post_s2mm_sts_ready),
        .s_axis_s2mm_sts_tdata(post_s2mm_sts_data),
        .m_axis_s2mm_tvalid(post_s2mm_valid),.m_axis_s2mm_tready(post_s2mm_ready),
        .m_axis_s2mm_tdata(post_s2mm_data),.m_axis_s2mm_tkeep(post_s2mm_keep),
        .m_axis_s2mm_tlast(post_s2mm_last),
        .hist_cmd_ready(1'b0),.hist_status_valid(1'b0),.hist_status_data(8'd0),
        .hist_data_valid(1'b0),.hist_data(128'd0),.hist_keep(16'd0),.hist_last(1'b0),
        .busy(post_busy),.done(post_done),.error(post_error),
        .cycle_count(post_cycle_count),.current_op(post_current_op),
        .lcc_debug_wait(dec_lcc_debug_wait),.area_counts,
        .profile_op_start(post_op_start),.profile_op_done(post_op_done),
        .profile_op_index(post_op_index),.profile_conv_metrics(),.profile_token_events());
    assign enc_current_op=enc_current_op_raw;
endmodule
