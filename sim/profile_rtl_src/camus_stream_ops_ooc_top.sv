`timescale 1ns/1ps

// OOC resource/timing wrapper for the non-convolution stream operators.
module camus_stream_ops_ooc_top (
    input  logic clk,
    input  logic rst,

    input  logic pool_start,
    input  logic [8:0] pool_width,
    input  logic [8:0] pool_height,
    input  logic [2:0] pool_groups,
    input  logic pool_s_valid,
    output logic pool_s_ready,
    input  logic [63:0] pool_s_data,
    input  logic pool_s_last,
    output logic pool_m_valid,
    input  logic pool_m_ready,
    output logic [63:0] pool_m_data,
    output logic pool_m_last,
    output logic pool_busy,
    output logic pool_done,
    output logic pool_error,

    input  logic history_clear,
    input  logic history_write_start,
    input  logic history_write_valid,
    output logic history_write_ready,
    input  logic [63:0] history_write_data,
    input  logic history_write_last,
    output logic history_write_done,
    input  logic history_read_start,
    input  logic [15:0] history_pixels,
    input  logic [2:0] history_groups,
    output logic history_valid,
    input  logic history_ready,
    output logic [63:0] history_data,
    output logic history_last,
    output logic history_done,
    output logic [1:0] history_count,
    output logic history_error,

    input  logic arg_valid,
    output logic arg_ready,
    input  logic [31:0] arg_logits,
    input  logic arg_last,
    output logic mask_valid,
    input  logic mask_ready,
    output logic [7:0] mask_class,
    output logic mask_last,

    input  logic address_start,
    input  logic [8:0] low_width,
    input  logic [8:0] low_height,
    input  logic [2:0] project_groups,
    input  logic [2:0] skip_groups,
    output logic address_valid,
    input  logic address_ready,
    output logic address_skip,
    output logic [19:0] address_word,
    output logic [2:0] address_group,
    output logic address_last,
    output logic address_busy,
    output logic address_done,
    output logic address_error
);
    camus_pool2x2_axis #(.MAX_WIDTH(256), .MAX_GROUPS(2)) u_pool (
        .clk(clk), .rst(rst), .start(pool_start),
        .width(pool_width), .height(pool_height), .groups(pool_groups),
        .s_valid(pool_s_valid), .s_ready(pool_s_ready), .s_data(pool_s_data),
        .s_last(pool_s_last), .m_valid(pool_m_valid), .m_ready(pool_m_ready),
        .m_data(pool_m_data), .m_last(pool_m_last), .busy(pool_busy),
        .done(pool_done), .error(pool_error)
    );

    camus_bottleneck_history #(.DEPTH(4096)) u_history (
        .clk(clk), .rst(rst), .clear_history(history_clear),
        .write_start(history_write_start), .write_valid(history_write_valid),
        .write_ready(history_write_ready), .write_data(history_write_data),
        .write_last(history_write_last), .write_done(history_write_done),
        .temporal_start(history_read_start), .pixels(history_pixels),
        .groups_per_frame(history_groups), .temporal_valid(history_valid),
        .temporal_ready(history_ready), .temporal_data(history_data),
        .temporal_last(history_last), .temporal_done(history_done),
        .history_count(history_count), .error(history_error)
    );

    camus_argmax4_axis u_argmax (
        .clk(clk), .rst(rst), .s_valid(arg_valid), .s_ready(arg_ready),
        .s_logits(arg_logits), .s_last(arg_last), .m_valid(mask_valid),
        .m_ready(mask_ready), .m_class(mask_class), .m_last(mask_last)
    );

    camus_nearest_concat_addrgen u_address (
        .clk(clk), .rst(rst), .start(address_start),
        .low_width(low_width), .low_height(low_height),
        .project_groups(project_groups), .skip_groups(skip_groups),
        .request_valid(address_valid), .request_ready(address_ready),
        .request_skip(address_skip), .request_word_address(address_word),
        .output_group(address_group), .output_last(address_last),
        .busy(address_busy), .done(address_done), .error(address_error)
    );
endmodule
