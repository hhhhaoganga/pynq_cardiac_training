`timescale 1ns/1ps
// Two real encoder convolutions with same-padding and a pixel-width bridge.
// The first layer emits PE-folded groups; the repacker/FIFO restores one
// 16-channel pixel before the second layer consumes its raster stream.
module camus_enc12_same_chain #(
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
    logic l0_valid, l0_ready, l0_pixel_last, l0_last, l0_busy, l0_done;
    logic signed [15:0] l0_data;
    logic repack_valid;
    logic signed [127:0] repack_data;
    logic repack_busy;
    logic fifo_in_ready, fifo_valid, fifo_out_ready;
    logic signed [127:0] fifo_data;
    logic l1_busy, l1_done;

    camus_pad2_stream #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .IN_CH(3), .OUT_CH(16), .PE(PE)
    ) l0 (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(l0_valid), .out_data(l0_data),
        .out_pixel_last(l0_pixel_last), .out_last(l0_last),
        .busy(l0_busy), .done(l0_done)
    );

    camus_feature_repacker #(.PE(PE), .OUT_CH(16)) repack (
        .clk, .rst, .in_valid(l0_valid), .in_data(l0_data),
        .in_pixel_last(l0_pixel_last), .out_valid(repack_valid),
        .out_data(repack_data), .busy(repack_busy)
    );

    camus_feature_fifo #(.WIDTH(128), .DEPTH(FIFO_DEPTH)) pixel_fifo (
        .clk, .rst,
        .in_valid(repack_valid), .in_ready(fifo_in_ready), .in_data(repack_data),
        .out_valid(fifo_valid), .out_ready(fifo_out_ready), .out_data(fifo_data),
        .overflow(fifo_overflow)
    );

    camus_pad2_stream #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .IN_CH(16), .OUT_CH(16),
        .LAYER_ID(1), .PE(PE)
    ) l1 (
        .clk, .rst, .start,
        .in_valid(fifo_valid), .in_pixel(fifo_data), .in_ready(fifo_out_ready),
        .out_valid, .out_data, .out_pixel_last, .out_last,
        .busy(l1_busy), .done(l1_done)
    );

    assign busy = l0_busy || repack_busy || fifo_valid || l1_busy;
    assign done = l1_done;
endmodule
