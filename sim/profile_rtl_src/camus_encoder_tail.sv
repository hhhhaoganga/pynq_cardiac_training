`timescale 1ns/1ps
// Real-weight encoder tail after the existing 16->32 stage.
//
// Input:  128x128 raster, 32 channels (the output of enc2.layers.0/.2)
// Output: 32x32 raster, 128 channels, PE-folded into 2-channel beats
//
// This block covers the remaining encoder expansion:
//   32->32, pool, 32->64->64, pool, 64->128->128.
module camus_encoder_tail #(
    parameter integer WIDTH = 128,
    parameter integer HEIGHT = 128,
    parameter integer PE = 2,
    parameter integer FIFO_DEPTH = 1024
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic in_valid,
    input logic signed [32*8-1:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [PE*8-1:0] out_data,
    output logic out_pixel_last,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic fifo_overflow
);
    logic l3_valid, l3_pixel_last, l3_last, l3_busy, l3_done;
    logic signed [PE*8-1:0] l3_data;
    logic repack3_valid;
    logic signed [32*8-1:0] repack3_data;
    logic pool3_valid, pool3_last;
    logic signed [32*8-1:0] pool3_data;

    logic block4_valid, block4_pixel_last, block4_last, block4_busy, block4_done;
    logic signed [PE*8-1:0] block4_data;
    logic repack4_valid;
    logic signed [64*8-1:0] repack4_data;
    logic pool4_valid, pool4_last;
    logic signed [64*8-1:0] pool4_data;

    logic block5_busy, block5_done;

    camus_pad2_stream #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .IN_CH(32), .OUT_CH(32),
        .LAYER_ID(3), .PE(PE)
    ) enc2_layer2 (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(l3_valid), .out_data(l3_data),
        .out_pixel_last(l3_pixel_last), .out_last(l3_last),
        .busy(l3_busy), .done(l3_done)
    );

    camus_feature_repacker #(.PE(PE), .OUT_CH(32)) repack3 (
        .clk, .rst, .in_valid(l3_valid), .in_data(l3_data),
        .in_pixel_last(l3_pixel_last), .out_valid(repack3_valid),
        .out_data(repack3_data), .busy()
    );

    camus_pool2x2_stream #(.WIDTH(WIDTH), .CHANNELS(32)) pool3 (
        .clk, .rst, .in_valid(repack3_valid), .in_data(repack3_data),
        .in_last(l3_last),
        .in_ready(), .out_valid(pool3_valid), .out_data(pool3_data),
        .out_last(pool3_last)
    );

    camus_two_conv_chain #(
        .WIDTH(WIDTH/2), .HEIGHT(HEIGHT/2), .IN_CH(32), .MID_CH(64),
        .OUT_CH(64), .LAYER_A(4), .LAYER_B(5), .PE(PE),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) enc3_block (
        .clk, .rst, .start,
        .in_valid(pool3_valid), .in_pixel(pool3_data), .in_ready(),
        .out_valid(block4_valid), .out_data(block4_data),
        .out_pixel_last(block4_pixel_last), .out_last(block4_last),
        .busy(block4_busy), .done(block4_done), .fifo_overflow()
    );

    camus_feature_repacker #(.PE(PE), .OUT_CH(64)) repack4 (
        .clk, .rst, .in_valid(block4_valid), .in_data(block4_data),
        .in_pixel_last(block4_pixel_last), .out_valid(repack4_valid),
        .out_data(repack4_data), .busy()
    );

    camus_pool2x2_stream #(.WIDTH(WIDTH/2), .CHANNELS(64)) pool4 (
        .clk, .rst, .in_valid(repack4_valid), .in_data(repack4_data),
        .in_last(block4_last), .in_ready(), .out_valid(pool4_valid),
        .out_data(pool4_data), .out_last(pool4_last)
    );

    camus_two_conv_chain #(
        .WIDTH(WIDTH/4), .HEIGHT(HEIGHT/4), .IN_CH(64), .MID_CH(128),
        .OUT_CH(128), .LAYER_A(6), .LAYER_B(7), .PE(PE),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) enc4_block (
        .clk, .rst, .start,
        .in_valid(pool4_valid), .in_pixel(pool4_data), .in_ready(),
        .out_valid, .out_data, .out_pixel_last, .out_last,
        .busy(block5_busy), .done(block5_done), .fifo_overflow()
    );

    assign busy = l3_busy || block4_busy || block5_busy || out_valid;
    assign done = block5_done;
    assign fifo_overflow = 1'b0;
endmodule
