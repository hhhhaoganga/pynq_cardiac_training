`timescale 1ns/1ps
// Two same-padding PE2 convolutions with a full-pixel bridge between them.
// The bridge is intentionally explicit so each layer can be checked against
// its own software golden before the larger encoder is assembled.
module camus_two_conv_chain #(
    parameter integer WIDTH = 64,
    parameter integer HEIGHT = 64,
    parameter integer IN_CH = 32,
    parameter integer MID_CH = 64,
    parameter integer OUT_CH = 64,
    parameter integer LAYER_A = 4,
    parameter integer LAYER_B = 5,
    parameter integer PE = 2,
    parameter integer FIFO_DEPTH = 1024
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic in_valid,
    input logic signed [IN_CH*8-1:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [PE*8-1:0] out_data,
    output logic out_pixel_last,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic fifo_overflow
);
    logic a_valid, a_pixel_last, a_last, a_busy, a_done;
    logic signed [PE*8-1:0] a_data;
    logic repack_valid;
    logic signed [MID_CH*8-1:0] repack_data;
    logic fifo_in_ready, fifo_valid, fifo_out_ready;
    logic signed [MID_CH*8-1:0] fifo_data;
    logic b_busy, b_done;

    camus_pad2_stream #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .IN_CH(IN_CH), .OUT_CH(MID_CH),
        .LAYER_ID(LAYER_A), .PE(PE)
    ) layer_a (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(a_valid), .out_data(a_data),
        .out_pixel_last(a_pixel_last), .out_last(a_last),
        .busy(a_busy), .done(a_done)
    );

    camus_feature_repacker #(.PE(PE), .OUT_CH(MID_CH)) repack_a (
        .clk, .rst, .in_valid(a_valid), .in_data(a_data),
        .in_pixel_last(a_pixel_last), .out_valid(repack_valid),
        .out_data(repack_data), .busy()
    );

    camus_feature_fifo #(.WIDTH(MID_CH*8), .DEPTH(FIFO_DEPTH)) pixel_fifo (
        .clk, .rst,
        .in_valid(repack_valid), .in_ready(fifo_in_ready), .in_data(repack_data),
        .out_valid(fifo_valid), .out_ready(fifo_out_ready), .out_data(fifo_data),
        .overflow(fifo_overflow)
    );

    camus_pad2_stream #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .IN_CH(MID_CH), .OUT_CH(OUT_CH),
        .LAYER_ID(LAYER_B), .PE(PE)
    ) layer_b (
        .clk, .rst, .start,
        .in_valid(fifo_valid), .in_pixel(fifo_data), .in_ready(fifo_out_ready),
        .out_valid, .out_data, .out_pixel_last, .out_last,
        .busy(b_busy), .done(b_done)
    );

    assign busy = a_busy || fifo_valid || b_busy;
    assign done = b_done;
endmodule
