`timescale 1ns/1ps
// Two real encoder layers connected through folded-group repacking and an
// elastic feature FIFO.  This is a frame-level integration kernel for bringup
// and timing estimation; production width/height and DDR tiling are parameters
// of the next wrapper.
module camus_enc12_chain #(
    parameter integer WIDTH = 5,
    parameter integer PE = 2
) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    input logic signed [23:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [15:0] out_data,
    output logic out_pixel_last,
    output logic busy,
    output logic fifo_overflow
);
    logic l0_valid, l0_pixel_last, l0_busy;
    logic signed [15:0] l0_data;
    logic packed_valid;
    logic signed [127:0] packed_data;
    logic fifo_valid, fifo_ready;
    logic signed [127:0] fifo_data;
    logic l2_busy;

    camus_conv3x3_pe2_layer #(.LAYER_ID(0), .WIDTH(WIDTH), .IN_CH(3), .OUT_CH(16)) l0 (
        .clk, .rst, .in_valid, .in_pixel, .in_ready, .out_valid(l0_valid),
        .out_data(l0_data), .out_pixel_last(l0_pixel_last), .out_last(), .busy(l0_busy));
    camus_feature_repacker repack (
        .clk, .rst, .in_valid(l0_valid), .in_data(l0_data),
        .in_pixel_last(l0_pixel_last), .out_valid(packed_valid), .out_data(packed_data), .busy());
    camus_feature_fifo #(.WIDTH(128), .DEPTH(16)) fifo (
        .clk, .rst, .in_valid(packed_valid), .in_ready(), .in_data(packed_data),
        .out_valid(fifo_valid), .out_ready(fifo_ready), .out_data(fifo_data),
        .overflow(fifo_overflow));
    camus_conv3x3_pe2_layer #(.LAYER_ID(1), .WIDTH(3), .IN_CH(16), .OUT_CH(16)) l2 (
        .clk, .rst, .in_valid(fifo_valid && fifo_ready), .in_pixel(fifo_data),
        .in_ready(fifo_ready), .out_valid, .out_data, .out_pixel_last,
        .out_last(), .busy(l2_busy));
    assign busy = l0_busy || l2_busy || fifo_valid;
endmodule
