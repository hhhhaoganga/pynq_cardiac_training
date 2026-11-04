`timescale 1ns/1ps

// Decoder phase: history-fed temporal convolution, three projected nearest
// concat stages, refinement convolutions, head, Argmax, and largest-component
// mask cleanup.
module camus_decoder_phase_executor #(
    parameter integer FIRST_OP = 11,
    parameter integer LAST_OP = 28
) (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base, input logic [31:0] mask_base,
    input logic [31:0] skip_base, input logic [31:0] scratch_base,
    input logic [31:0] watchdog_limit, input logic history_available,

    output logic m_axis_mm2s_cmd_tvalid,
    input logic m_axis_mm2s_cmd_tready,
    output logic [71:0] m_axis_mm2s_cmd_tdata,
    input logic s_axis_mm2s_sts_tvalid,
    output logic s_axis_mm2s_sts_tready,
    input logic [7:0] s_axis_mm2s_sts_tdata,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tlast,

    output logic m_axis_s2mm_cmd_tvalid,
    input logic m_axis_s2mm_cmd_tready,
    output logic [71:0] m_axis_s2mm_cmd_tdata,
    input logic s_axis_s2mm_sts_tvalid,
    output logic s_axis_s2mm_sts_tready,
    input logic [7:0] s_axis_s2mm_sts_tdata,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tlast,

    output logic hist_cmd_valid,
    input logic hist_cmd_ready,
    output logic [71:0] hist_cmd_data,
    input logic hist_status_valid,
    output logic hist_status_ready,
    input logic [7:0] hist_status_data,
    input logic hist_data_valid,
    output logic hist_data_ready,
    input logic [127:0] hist_data,
    input logic [15:0] hist_keep,
    input logic hist_last,

    output logic busy, output logic done, output logic error,
    output logic [63:0] cycle_count,
    output logic [4:0] current_op,
    output logic [4:0] lcc_debug_wait,
    output logic [50:0] area_counts,
    output logic profile_op_start, output logic profile_op_done,
    output logic [4:0] profile_op_index,
    output logic [127:0] profile_conv_metrics,
    output logic [2:0] profile_token_events
);
    localparam logic [2:0] OP_CONV=3'd0,OP_HISTORY=3'd2;
    localparam logic [2:0] OP_CONCAT=3'd3,OP_ARGMAX=3'd4,OP_LCC=3'd5,OP_SE=3'd6;
    logic op_start,op_done,op_error,history_done;
    logic [2:0] op_kind;
    logic [4:0] op_index,layer_index;
    logic [31:0] source_address,source_b_address,dest_address;
    logic [8:0] height,width,tile_rows;
    logic [3:0] input_groups,output_groups,stored_output_groups;
    logic kernel_3x3,relu_enable;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [19:0] input_row_words;
    logic [31:0] input_row_bytes,input_tile_stride_bytes,output_row_bytes;
    logic conv_selected,concat_selected,argmax_selected,lcc_selected,history_selected,se_selected;
    logic conv_from_history;
    logic [31:0] conv_input_base;
    logic hist_cmd_raw_valid,hist_cmd_raw_ready;
    logic [71:0] hist_cmd_raw_data;

    logic [1:0] concat_stage;
    logic concat_job_valid;
    logic [8:0] concat_low_width,concat_low_height,concat_tile_rows;
    logic [5:0] concat_project_channels,concat_skip_channels;
    logic signed [31:0] concat_project_multiplier,concat_skip_multiplier;
    logic signed [6:0] concat_project_shift,concat_skip_shift;

    logic conv_mm_cmd_valid,conv_mm_cmd_ready;
    logic [71:0] conv_mm_cmd_data;
    logic conv_mm_sts_valid,conv_mm_sts_ready;
    logic [7:0] conv_mm_sts_data;
    logic conv_mm_valid,conv_mm_ready,conv_mm_last;
    logic [127:0] conv_mm_data;
    logic [15:0] conv_mm_keep;
    logic conv_s2_cmd_valid,conv_s2_cmd_ready;
    logic [71:0] conv_s2_cmd_data;
    logic conv_s2_sts_valid,conv_s2_sts_ready;
    logic [7:0] conv_s2_sts_data;
    logic conv_s2_valid,conv_s2_ready,conv_s2_last;
    logic [127:0] conv_s2_data;
    logic [15:0] conv_s2_keep;
    logic conv_busy,conv_done,conv_error;
    logic [31:0] conv_cycles,conv_load_wait,conv_compute;
    logic [31:0] conv_output_wait,conv_output_stall;
    logic [15:0] conv_strips;
    logic [2:0] conv_token_events;

    logic concat_mm_cmd_valid,concat_mm_cmd_ready;
    logic [71:0] concat_mm_cmd_data;
    logic concat_mm_pipe_valid,concat_mm_pipe_ready;
    logic concat_mm_slice_s_ready;
    logic [71:0] concat_mm_pipe_data;
    logic concat_s2_pipe_valid,concat_s2_pipe_ready;
    logic concat_s2_slice_s_ready;
    logic [71:0] concat_s2_pipe_data;
    logic concat_mm_sts_valid,concat_mm_sts_ready;
    logic [7:0] concat_mm_sts_data;
    logic concat_mm_valid,concat_mm_ready,concat_mm_last;
    logic [127:0] concat_mm_data;
    logic [15:0] concat_mm_keep;
    logic concat_s2_cmd_valid,concat_s2_cmd_ready;
    logic [71:0] concat_s2_cmd_data;
    logic concat_s2_sts_valid,concat_s2_sts_ready;
    logic [7:0] concat_s2_sts_data;
    logic concat_s2_valid,concat_s2_ready,concat_s2_last;
    logic [127:0] concat_s2_data;
    logic [15:0] concat_s2_keep;
    logic concat_busy,concat_done,concat_error;
    logic [63:0] concat_cycles;
    logic [15:0] concat_tiles;

    logic se_mm_cmd_valid,se_mm_cmd_ready,se_mm_sts_valid,se_mm_sts_ready;
    logic [71:0] se_mm_cmd_data;
    logic [7:0] se_mm_sts_data;
    logic se_mm_valid,se_mm_ready,se_mm_last;
    logic [127:0] se_mm_data;
    logic [15:0] se_mm_keep;
    logic se_s2_cmd_valid,se_s2_cmd_ready,se_s2_sts_valid,se_s2_sts_ready;
    logic [71:0] se_s2_cmd_data;
    logic [7:0] se_s2_sts_data;
    logic se_s2_valid,se_s2_ready,se_s2_last;
    logic [127:0] se_s2_data;
    logic [15:0] se_s2_keep;
    logic se_busy,se_done,se_error;
    logic [63:0] se_cycles;

    `include "camus_se_quant_desc.svh"

    logic arg_mm_cmd_valid,arg_mm_cmd_ready;
    logic [71:0] arg_mm_cmd_data;
    logic arg_mm_sts_valid,arg_mm_sts_ready;
    logic [7:0] arg_mm_sts_data;
    logic arg_mm_valid,arg_mm_ready,arg_mm_last;
    logic [127:0] arg_mm_data;
    logic [15:0] arg_mm_keep;
    logic arg_s2_cmd_valid,arg_s2_cmd_ready;
    logic [71:0] arg_s2_cmd_data;
    logic arg_s2_sts_valid,arg_s2_sts_ready;
    logic [7:0] arg_s2_sts_data;
    logic arg_s2_valid,arg_s2_ready,arg_s2_last;
    logic [127:0] arg_s2_data;
    logic [15:0] arg_s2_keep;
    logic arg_busy,arg_done,arg_error;
    logic [63:0] arg_cycles;
    logic [31:0] arg_input_stall,arg_output_stall;

    logic lcc_mm_cmd_valid,lcc_mm_cmd_ready;
    logic [71:0] lcc_mm_cmd_data;
    logic lcc_mm_sts_valid,lcc_mm_sts_ready;
    logic [7:0] lcc_mm_sts_data;
    logic lcc_mm_valid,lcc_mm_ready,lcc_mm_last;
    logic [127:0] lcc_mm_data;
    logic [15:0] lcc_mm_keep;
    logic lcc_s2_cmd_valid,lcc_s2_cmd_ready;
    logic [71:0] lcc_s2_cmd_data;
    logic lcc_s2_sts_valid,lcc_s2_sts_ready;
    logic [7:0] lcc_s2_sts_data;
    logic lcc_s2_valid,lcc_s2_ready,lcc_s2_last;
    logic [127:0] lcc_s2_data;
    logic [15:0] lcc_s2_keep;
    logic lcc_busy,lcc_done,lcc_error,lcc_overflow;
    logic [63:0] lcc_cycles;
    logic [15:0] lcc_labels_used;

    assign current_op=op_index;
    assign profile_op_start = op_start;
    assign profile_op_done = op_done;
    assign profile_op_index = op_index;
    assign profile_conv_metrics = conv_selected
        ? {conv_output_stall, conv_output_wait, conv_compute, conv_load_wait} : 128'd0;
    assign profile_token_events = conv_selected ? conv_token_events : 3'd0;
    assign conv_selected=op_kind==OP_CONV;
    assign history_selected=op_kind==OP_HISTORY;
    assign concat_selected=op_kind==OP_CONCAT;
    assign argmax_selected=op_kind==OP_ARGMAX;
    assign lcc_selected=op_kind==OP_LCC;
    assign se_selected=op_kind==OP_SE;
    assign conv_from_history=conv_selected&&op_index==5'd12;
    // The history bridge interprets the DataMover address as a byte offset
    // inside the temporal tensor, not as a PS DDR address.
    assign conv_input_base=conv_from_history?32'd0:source_address;
    assign concat_stage = op_index == 5'd15 ? 2'd0
        : op_index == 5'd19 ? 2'd1 : 2'd2;
    assign op_done = conv_selected ? conv_done
        : history_selected ? history_done
        : se_selected ? se_done
        : concat_selected ? concat_done
        : argmax_selected ? arg_done
        : lcc_selected ? lcc_done : 1'b0;
    assign op_error = conv_selected ? conv_error
        : history_selected ? !history_available
        : se_selected ? se_error
        : concat_selected ? (concat_error || !concat_job_valid)
        : argmax_selected ? arg_error
        : lcc_selected ? (lcc_error||lcc_overflow) : 1'b1;

    always_ff @(posedge clk) begin
        if(rst) history_done<=0;
        else history_done<=op_start&&history_selected&&history_available;
    end

    camus_phase_scheduler #(.FIRST_OP(FIRST_OP),.LAST_OP(LAST_OP)) u_scheduler (
        .clk,.rst,.start,.op_done,.op_error,.input_base,.mask_base,.skip_base,
        .scratch_base,.op_start,.op_kind,.op_index,.layer_index,.source_address,
        .source_b_address,.dest_address,.height,.width,.tile_rows,.input_groups,
        .output_groups,.stored_output_groups,.kernel_3x3,.weight_base,
        .parameter_base,.tokens_per_output_group,.relu_enable,.input_row_words,
        .input_row_bytes,.input_tile_stride_bytes,.output_row_bytes,
        .busy,.done,.error,.cycle_count);

    generate if (FIRST_OP < 27) begin : g_network
    camus_axis72_register_slice u_hist_cmd_slice (
        .clk,.rst,.s_valid(hist_cmd_raw_valid),.s_ready(hist_cmd_raw_ready),
        .s_data(hist_cmd_raw_data),.m_valid(hist_cmd_valid),
        .m_ready(hist_cmd_ready),.m_data(hist_cmd_data));


    camus_concat_job_rom u_concat_job (
        .stage_index(concat_stage),.valid(concat_job_valid),
        .low_width(concat_low_width),.low_height(concat_low_height),
        .project_channels(concat_project_channels),
        .skip_channels(concat_skip_channels),.tile_low_rows(concat_tile_rows),
        .project_multiplier(concat_project_multiplier),
        .project_shift(concat_project_shift),
        .skip_multiplier(concat_skip_multiplier),.skip_shift(concat_skip_shift));

    camus_datamover_strip_executor #(.SIMD(16)) u_conv (
        .clk,.rst,.start(op_start&&conv_selected),
        .input_base_bytes(conv_input_base),
        .output_base_bytes(LAST_OP == 26 && op_index == 26 ? mask_base : dest_address),
        .input_row_words,.input_row_bytes,.input_tile_stride_bytes,
        .output_row_bytes,.frame_height(height),.width,.tile_rows,.input_groups,
        .output_groups,.kernel_3x3,.weight_base,.parameter_base,
        .tokens_per_output_group,.relu_enable,.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(conv_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(conv_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(conv_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(conv_mm_sts_valid),
        .s_axis_mm2s_sts_tready(conv_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(conv_mm_sts_data),
        .s_axis_mm2s_tvalid(conv_mm_valid),.s_axis_mm2s_tready(conv_mm_ready),
        .s_axis_mm2s_tdata(conv_mm_data),.s_axis_mm2s_tkeep(conv_mm_keep),
        .s_axis_mm2s_tlast(conv_mm_last),
        .m_axis_s2mm_cmd_tvalid(conv_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(conv_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(conv_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(conv_s2_sts_valid),
        .s_axis_s2mm_sts_tready(conv_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(conv_s2_sts_data),
        .m_axis_s2mm_tvalid(conv_s2_valid),.m_axis_s2mm_tready(conv_s2_ready),
        .m_axis_s2mm_tdata(conv_s2_data),.m_axis_s2mm_tkeep(conv_s2_keep),
        .m_axis_s2mm_tlast(conv_s2_last),.busy(conv_busy),.done(conv_done),
        .error(conv_error),.cycle_count(conv_cycles),
        .load_wait_cycles(conv_load_wait),.compute_cycles(conv_compute),
        .output_wait_cycles(conv_output_wait),
        .output_stall_count(conv_output_stall),.strips_completed(conv_strips),
        .profile_token_events(conv_token_events));

    camus_se_datamover_executor u_se (
        .clk,.rst,.start(op_start&&se_selected),
        .input_base_bytes(source_address),.output_base_bytes(dest_address),
        .command_tag(op_index[3:0]),.watchdog_limit,
        .gap_multiplier(CAMUS_SE_GAP_MULTIPLIER),
        .gap_shift(CAMUS_SE_GAP_SHIFT),
        .se1_to_se3_multiplier(CAMUS_SE_HIDDEN_MULTIPLIER),
        .se1_to_se3_shift(CAMUS_SE_HIDDEN_SHIFT),
        .product_multiplier(CAMUS_SE_PRODUCT_MULTIPLIER),
        .product_shift(CAMUS_SE_PRODUCT_SHIFT),
        .m_axis_mm2s_cmd_tvalid(se_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(se_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(se_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(se_mm_sts_valid),
        .s_axis_mm2s_sts_tready(se_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(se_mm_sts_data),
        .s_axis_mm2s_tvalid(se_mm_valid),.s_axis_mm2s_tready(se_mm_ready),
        .s_axis_mm2s_tdata(se_mm_data),.s_axis_mm2s_tkeep(se_mm_keep),
        .s_axis_mm2s_tlast(se_mm_last),
        .m_axis_s2mm_cmd_tvalid(se_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(se_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(se_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(se_s2_sts_valid),
        .s_axis_s2mm_sts_tready(se_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(se_s2_sts_data),
        .m_axis_s2mm_tvalid(se_s2_valid),.m_axis_s2mm_tready(se_s2_ready),
        .m_axis_s2mm_tdata(se_s2_data),.m_axis_s2mm_tkeep(se_s2_keep),
        .m_axis_s2mm_tlast(se_s2_last),
        .busy(se_busy),.done(se_done),.error(se_error),.cycle_count(se_cycles));

    camus_axis72_register_slice u_concat_mm_cmd_slice (
        .clk,.rst,.s_valid(concat_mm_cmd_valid),.s_ready(concat_mm_slice_s_ready),
        .s_data(concat_mm_cmd_data),.m_valid(concat_mm_pipe_valid),
        .m_ready(concat_mm_pipe_ready),.m_data(concat_mm_pipe_data));

    camus_axis72_register_slice u_concat_s2_cmd_slice (
        .clk,.rst,.s_valid(concat_s2_cmd_valid),.s_ready(concat_s2_slice_s_ready),
        .s_data(concat_s2_cmd_data),.m_valid(concat_s2_pipe_valid),
        .m_ready(concat_s2_pipe_ready),.m_data(concat_s2_pipe_data));

    camus_nearest_concat_datamover_executor u_concat (
        .clk,.rst,.start(op_start&&concat_selected),
        .project_base_bytes(source_address),.skip_base_bytes(source_b_address),
        .output_base_bytes(dest_address),.low_width(concat_low_width),
        .low_height(concat_low_height),
        .project_channels(concat_project_channels),
        .skip_channels(concat_skip_channels),.tile_low_rows(concat_tile_rows),
        .project_multiplier(concat_project_multiplier),
        .project_shift(concat_project_shift),
        .skip_multiplier(concat_skip_multiplier),.skip_shift(concat_skip_shift),
        .watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(concat_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(concat_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(concat_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(concat_mm_sts_valid),
        .s_axis_mm2s_sts_tready(concat_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(concat_mm_sts_data),
        .s_axis_mm2s_tvalid(concat_mm_valid),.s_axis_mm2s_tready(concat_mm_ready),
        .s_axis_mm2s_tdata(concat_mm_data),.s_axis_mm2s_tkeep(concat_mm_keep),
        .s_axis_mm2s_tlast(concat_mm_last),
        .m_axis_s2mm_cmd_tvalid(concat_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(concat_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(concat_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(concat_s2_sts_valid),
        .s_axis_s2mm_sts_tready(concat_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(concat_s2_sts_data),
        .m_axis_s2mm_tvalid(concat_s2_valid),
        .m_axis_s2mm_tready(concat_s2_ready),
        .m_axis_s2mm_tdata(concat_s2_data),
        .m_axis_s2mm_tkeep(concat_s2_keep),
        .m_axis_s2mm_tlast(concat_s2_last),.busy(concat_busy),
        .done(concat_done),.error(concat_error),.cycle_count(concat_cycles),
        .tiles_completed(concat_tiles));

    end else begin : g_no_network
        assign hist_cmd_valid=0, hist_cmd_data=0, hist_cmd_raw_ready=0;
        assign conv_mm_cmd_valid=0,conv_mm_cmd_data=0,conv_mm_sts_ready=0;
        assign conv_mm_ready=0,conv_s2_cmd_valid=0,conv_s2_cmd_data=0;
        assign conv_s2_sts_ready=0,conv_s2_valid=0,conv_s2_data=0;
        assign conv_s2_keep=0,conv_s2_last=0,conv_busy=0,conv_done=0,conv_error=0;
        assign conv_cycles=0,conv_load_wait=0,conv_compute=0;
        assign conv_output_wait=0,conv_output_stall=0,conv_strips=0,conv_token_events=0;
        assign concat_job_valid=0,concat_low_width=0,concat_low_height=0,concat_tile_rows=0;
        assign concat_project_channels=0,concat_skip_channels=0;
        assign concat_project_multiplier=0,concat_skip_multiplier=0;
        assign concat_project_shift=0,concat_skip_shift=0;
        assign concat_mm_cmd_valid=0,concat_mm_cmd_data=0,concat_mm_pipe_valid=0;
        assign concat_mm_pipe_data=0,concat_mm_slice_s_ready=0,concat_mm_sts_ready=0;
        assign concat_mm_ready=0,concat_s2_cmd_valid=0,concat_s2_cmd_data=0;
        assign concat_s2_pipe_valid=0,concat_s2_pipe_data=0,concat_s2_slice_s_ready=0;
        assign concat_s2_sts_ready=0,concat_s2_valid=0,concat_s2_data=0;
        assign concat_s2_keep=0,concat_s2_last=0,concat_busy=0,concat_done=0;
        assign concat_error=0,concat_cycles=0,concat_tiles=0;
        assign se_mm_cmd_valid=0,se_mm_cmd_data=0,se_mm_sts_ready=0;
        assign se_mm_ready=0,se_s2_cmd_valid=0,se_s2_cmd_data=0;
        assign se_s2_sts_ready=0,se_s2_valid=0,se_s2_data=0;
        assign se_s2_keep=0,se_s2_last=0,se_busy=0,se_done=0,se_error=0,se_cycles=0;
    end endgenerate

    generate if (LAST_OP >= 27) begin : g_postprocess
    camus_argmax_datamover_executor u_argmax (
        .clk,.rst,.start(op_start&&argmax_selected),
        .input_base_bytes(FIRST_OP == 27 ? scratch_base : source_address),
        .mask_base_bytes(dest_address),
        .width,.height,.command_tag(op_index[3:0]),.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(arg_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(arg_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(arg_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(arg_mm_sts_valid),
        .s_axis_mm2s_sts_tready(arg_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(arg_mm_sts_data),
        .s_axis_mm2s_tvalid(arg_mm_valid),.s_axis_mm2s_tready(arg_mm_ready),
        .s_axis_mm2s_tdata(arg_mm_data),.s_axis_mm2s_tkeep(arg_mm_keep),
        .s_axis_mm2s_tlast(arg_mm_last),
        .m_axis_s2mm_cmd_tvalid(arg_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(arg_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(arg_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(arg_s2_sts_valid),
        .s_axis_s2mm_sts_tready(arg_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(arg_s2_sts_data),
        .m_axis_s2mm_tvalid(arg_s2_valid),.m_axis_s2mm_tready(arg_s2_ready),
        .m_axis_s2mm_tdata(arg_s2_data),.m_axis_s2mm_tkeep(arg_s2_keep),
        .m_axis_s2mm_tlast(arg_s2_last),.busy(arg_busy),.done(arg_done),
        .error(arg_error),.cycle_count(arg_cycles),
        .input_stall_cycles(arg_input_stall),
        .output_stall_cycles(arg_output_stall));

    camus_lcc_datamover_executor #(.MAX_LABELS(512)) u_lcc (
        .clk,.rst,.start(op_start&&lcc_selected),
        .mask_base_bytes(source_address),
        .label_base_bytes(FIRST_OP == 27 ? scratch_base + 32'h0008_0000 : source_b_address),
        .width,.height,.command_tag(op_index[3:0]),.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(lcc_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(lcc_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(lcc_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(lcc_mm_sts_valid),
        .s_axis_mm2s_sts_tready(lcc_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(lcc_mm_sts_data),
        .s_axis_mm2s_tvalid(lcc_mm_valid),.s_axis_mm2s_tready(lcc_mm_ready),
        .s_axis_mm2s_tdata(lcc_mm_data),.s_axis_mm2s_tkeep(lcc_mm_keep),
        .s_axis_mm2s_tlast(lcc_mm_last),
        .m_axis_s2mm_cmd_tvalid(lcc_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(lcc_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(lcc_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(lcc_s2_sts_valid),
        .s_axis_s2mm_sts_tready(lcc_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(lcc_s2_sts_data),
        .m_axis_s2mm_tvalid(lcc_s2_valid),.m_axis_s2mm_tready(lcc_s2_ready),
        .m_axis_s2mm_tdata(lcc_s2_data),.m_axis_s2mm_tkeep(lcc_s2_keep),
        .m_axis_s2mm_tlast(lcc_s2_last),.busy(lcc_busy),.done(lcc_done),
        .error(lcc_error),.overflow(lcc_overflow),.cycle_count(lcc_cycles),
        .labels_used(lcc_labels_used),.debug_wait(lcc_debug_wait),.area_counts);

    end else begin : g_no_postprocess
        assign arg_mm_cmd_valid=0,arg_mm_cmd_data=0,arg_mm_sts_ready=0,arg_mm_ready=0;
        assign arg_s2_cmd_valid=0,arg_s2_cmd_data=0,arg_s2_sts_ready=0;
        assign arg_s2_valid=0,arg_s2_data=0,arg_s2_keep=0,arg_s2_last=0;
        assign arg_busy=0,arg_done=0,arg_error=0,arg_cycles=0;
        assign arg_input_stall=0,arg_output_stall=0;
        assign lcc_mm_cmd_valid=0,lcc_mm_cmd_data=0,lcc_mm_sts_ready=0,lcc_mm_ready=0;
        assign lcc_s2_cmd_valid=0,lcc_s2_cmd_data=0,lcc_s2_sts_ready=0;
        assign lcc_s2_valid=0,lcc_s2_data=0,lcc_s2_keep=0,lcc_s2_last=0;
        assign lcc_busy=0,lcc_done=0,lcc_error=0,lcc_overflow=0,lcc_cycles=0;
        assign lcc_labels_used=0,lcc_debug_wait=0,area_counts=0;
    end endgenerate

    always_comb begin
        m_axis_mm2s_cmd_tvalid=0;m_axis_mm2s_cmd_tdata=0;
        s_axis_mm2s_sts_tready=0;s_axis_mm2s_tready=0;
        m_axis_s2mm_cmd_tvalid=0;m_axis_s2mm_cmd_tdata=0;
        s_axis_s2mm_sts_tready=0;m_axis_s2mm_tvalid=0;
        m_axis_s2mm_tdata=0;m_axis_s2mm_tkeep=0;m_axis_s2mm_tlast=0;
        hist_cmd_raw_valid=0;hist_cmd_raw_data=0;hist_status_ready=0;hist_data_ready=0;
        concat_mm_pipe_ready=0;concat_s2_pipe_ready=0;

        conv_mm_cmd_ready=0;conv_mm_sts_valid=0;conv_mm_sts_data=0;
        conv_mm_valid=0;conv_mm_data=0;conv_mm_keep=0;conv_mm_last=0;
        conv_s2_cmd_ready=0;conv_s2_sts_valid=0;conv_s2_sts_data=0;
        conv_s2_ready=0;
        concat_mm_cmd_ready=0;concat_mm_sts_valid=0;concat_mm_sts_data=0;
        concat_mm_valid=0;concat_mm_data=0;concat_mm_keep=0;concat_mm_last=0;
        concat_s2_cmd_ready=0;
        concat_s2_sts_valid=0;concat_s2_sts_data=0;
        concat_s2_ready=0;
        se_mm_cmd_ready=0;se_mm_sts_valid=0;se_mm_sts_data=0;
        se_mm_valid=0;se_mm_data=0;se_mm_keep=0;se_mm_last=0;
        se_s2_cmd_ready=0;se_s2_sts_valid=0;se_s2_sts_data=0;
        se_s2_ready=0;
        arg_mm_cmd_ready=0;arg_mm_sts_valid=0;arg_mm_sts_data=0;
        arg_mm_valid=0;arg_mm_data=0;arg_mm_keep=0;arg_mm_last=0;
        arg_s2_cmd_ready=0;arg_s2_sts_valid=0;arg_s2_sts_data=0;arg_s2_ready=0;
        lcc_mm_cmd_ready=0;lcc_mm_sts_valid=0;lcc_mm_sts_data=0;
        lcc_mm_valid=0;lcc_mm_data=0;lcc_mm_keep=0;lcc_mm_last=0;
        lcc_s2_cmd_ready=0;lcc_s2_sts_valid=0;lcc_s2_sts_data=0;lcc_s2_ready=0;

        if(conv_selected) begin
            if(conv_from_history) begin
                hist_cmd_raw_valid=conv_mm_cmd_valid;
                hist_cmd_raw_data=conv_mm_cmd_data;
                conv_mm_cmd_ready=hist_cmd_raw_ready;
                conv_mm_sts_valid=hist_status_valid;
                conv_mm_sts_data=hist_status_data;
                hist_status_ready=conv_mm_sts_ready;
                conv_mm_valid=hist_data_valid;conv_mm_data=hist_data;
                conv_mm_keep=hist_keep;conv_mm_last=hist_last;
                hist_data_ready=conv_mm_ready;
            end else begin
                m_axis_mm2s_cmd_tvalid=conv_mm_cmd_valid;
                m_axis_mm2s_cmd_tdata=conv_mm_cmd_data;
                conv_mm_cmd_ready=m_axis_mm2s_cmd_tready;
                conv_mm_sts_valid=s_axis_mm2s_sts_tvalid;
                conv_mm_sts_data=s_axis_mm2s_sts_tdata;
                s_axis_mm2s_sts_tready=conv_mm_sts_ready;
                conv_mm_valid=s_axis_mm2s_tvalid;conv_mm_data=s_axis_mm2s_tdata;
                conv_mm_keep=s_axis_mm2s_tkeep;conv_mm_last=s_axis_mm2s_tlast;
                s_axis_mm2s_tready=conv_mm_ready;
            end
            m_axis_s2mm_cmd_tvalid=conv_s2_cmd_valid;
            m_axis_s2mm_cmd_tdata=conv_s2_cmd_data;
            conv_s2_cmd_ready=m_axis_s2mm_cmd_tready;
            conv_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            conv_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=conv_s2_sts_ready;
            m_axis_s2mm_tvalid=conv_s2_valid;m_axis_s2mm_tdata=conv_s2_data;
            m_axis_s2mm_tkeep=conv_s2_keep;m_axis_s2mm_tlast=conv_s2_last;
            conv_s2_ready=m_axis_s2mm_tready;
        end else if(se_selected) begin
            m_axis_mm2s_cmd_tvalid=se_mm_cmd_valid;
            m_axis_mm2s_cmd_tdata=se_mm_cmd_data;
            se_mm_cmd_ready=m_axis_mm2s_cmd_tready;
            se_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            se_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=se_mm_sts_ready;
            se_mm_valid=s_axis_mm2s_tvalid;
            se_mm_data=s_axis_mm2s_tdata;
            se_mm_keep=s_axis_mm2s_tkeep;
            se_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=se_mm_ready;
            m_axis_s2mm_cmd_tvalid=se_s2_cmd_valid;
            m_axis_s2mm_cmd_tdata=se_s2_cmd_data;
            se_s2_cmd_ready=m_axis_s2mm_cmd_tready;
            se_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            se_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=se_s2_sts_ready;
            m_axis_s2mm_tvalid=se_s2_valid;
            m_axis_s2mm_tdata=se_s2_data;
            m_axis_s2mm_tkeep=se_s2_keep;
            m_axis_s2mm_tlast=se_s2_last;
            se_s2_ready=m_axis_s2mm_tready;
        end else if(concat_selected) begin
            m_axis_mm2s_cmd_tvalid=concat_mm_pipe_valid;
            m_axis_mm2s_cmd_tdata=concat_mm_pipe_data;
            concat_mm_pipe_ready=m_axis_mm2s_cmd_tready;
            concat_mm_cmd_ready=concat_mm_slice_s_ready;
            concat_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            concat_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=concat_mm_sts_ready;
            concat_mm_valid=s_axis_mm2s_tvalid;concat_mm_data=s_axis_mm2s_tdata;
            concat_mm_keep=s_axis_mm2s_tkeep;concat_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=concat_mm_ready;
            m_axis_s2mm_cmd_tvalid=concat_s2_pipe_valid;
            m_axis_s2mm_cmd_tdata=concat_s2_pipe_data;
            concat_s2_pipe_ready=m_axis_s2mm_cmd_tready;
            concat_s2_cmd_ready=concat_s2_slice_s_ready;
            concat_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            concat_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=concat_s2_sts_ready;
            m_axis_s2mm_tvalid=concat_s2_valid;m_axis_s2mm_tdata=concat_s2_data;
            m_axis_s2mm_tkeep=concat_s2_keep;m_axis_s2mm_tlast=concat_s2_last;
            concat_s2_ready=m_axis_s2mm_tready;
        end else if(argmax_selected) begin
            m_axis_mm2s_cmd_tvalid=arg_mm_cmd_valid;
            m_axis_mm2s_cmd_tdata=arg_mm_cmd_data;
            arg_mm_cmd_ready=m_axis_mm2s_cmd_tready;
            arg_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            arg_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=arg_mm_sts_ready;
            arg_mm_valid=s_axis_mm2s_tvalid;arg_mm_data=s_axis_mm2s_tdata;
            arg_mm_keep=s_axis_mm2s_tkeep;arg_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=arg_mm_ready;
            m_axis_s2mm_cmd_tvalid=arg_s2_cmd_valid;
            m_axis_s2mm_cmd_tdata=arg_s2_cmd_data;
            arg_s2_cmd_ready=m_axis_s2mm_cmd_tready;
            arg_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            arg_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=arg_s2_sts_ready;
            m_axis_s2mm_tvalid=arg_s2_valid;m_axis_s2mm_tdata=arg_s2_data;
            m_axis_s2mm_tkeep=arg_s2_keep;m_axis_s2mm_tlast=arg_s2_last;
            arg_s2_ready=m_axis_s2mm_tready;
        end else if(lcc_selected) begin
            m_axis_mm2s_cmd_tvalid=lcc_mm_cmd_valid;
            m_axis_mm2s_cmd_tdata=lcc_mm_cmd_data;
            lcc_mm_cmd_ready=m_axis_mm2s_cmd_tready;
            lcc_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            lcc_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=lcc_mm_sts_ready;
            lcc_mm_valid=s_axis_mm2s_tvalid;lcc_mm_data=s_axis_mm2s_tdata;
            lcc_mm_keep=s_axis_mm2s_tkeep;lcc_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=lcc_mm_ready;
            m_axis_s2mm_cmd_tvalid=lcc_s2_cmd_valid;
            m_axis_s2mm_cmd_tdata=lcc_s2_cmd_data;
            lcc_s2_cmd_ready=m_axis_s2mm_cmd_tready;
            lcc_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            lcc_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=lcc_s2_sts_ready;
            m_axis_s2mm_tvalid=lcc_s2_valid;m_axis_s2mm_tdata=lcc_s2_data;
            m_axis_s2mm_tkeep=lcc_s2_keep;m_axis_s2mm_tlast=lcc_s2_last;
            lcc_s2_ready=m_axis_s2mm_tready;
        end
    end
endmodule
