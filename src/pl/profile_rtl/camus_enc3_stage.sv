`timescale 1ns/1ps
// First pooled encoder stage followed by the real 16->32 convolution.
// The pooled 16-channel pixels are buffered before the third layer because
// its same-padding wrapper consumes no source data during its inserted border.
module camus_enc3_stage #(
    parameter integer WIDTH = 256,
    parameter integer HEIGHT = 256,
    parameter integer PE = 2,
    parameter integer FIFO_DEPTH = 1024
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic in_valid,
    input logic signed [23:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [15:0] out_data,
    output logic out_pixel_last,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic fifo_overflow
);
    localparam integer PW = WIDTH / 2;
    localparam integer PH = HEIGHT / 2;
    logic pool_valid, pool_busy, pool_last, pool_done;
    logic signed [127:0] pool_data;
    logic fifo_valid, fifo_ready;
    logic signed [127:0] fifo_data;
    logic layer_busy, layer_in_ready;

    camus_enc12_pool_chain #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .PE(PE), .FIFO_DEPTH(FIFO_DEPTH)
    ) enc12_pool (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(pool_valid), .out_data(pool_data), .out_last(pool_last),
        .busy(pool_busy), .done(pool_done), .fifo_overflow
    );

    camus_feature_fifo #(.WIDTH(128), .DEPTH(FIFO_DEPTH)) pool_fifo (
        .clk, .rst,
        .in_valid(pool_valid), .in_ready(fifo_ready), .in_data(pool_data),
        .out_valid(fifo_valid), .out_ready(layer_in_ready), .out_data(fifo_data),
        .overflow()
    );

    camus_pad2_stream #(
        .WIDTH(PW), .HEIGHT(PH), .IN_CH(16), .OUT_CH(32),
        .LAYER_ID(2), .PE(PE)
    ) enc3 (
        .clk, .rst, .start,
        .in_valid(fifo_valid), .in_pixel(fifo_data), .in_ready(layer_in_ready),
        .out_valid, .out_data, .out_pixel_last, .out_last,
        .busy(layer_busy), .done(done)
    );

    assign busy = pool_busy || layer_busy || fifo_valid;
endmodule
