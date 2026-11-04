`timescale 1ns/1ps
// Standalone real-weight 32->64->64 encoder block at 64x64.
module camus_enc3_block (
    input logic clk,
    input logic rst,
    input logic start,
    input logic in_valid,
    input logic signed [32*8-1:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [2*8-1:0] out_data,
    output logic out_pixel_last,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic fifo_overflow
);
    camus_two_conv_chain #(
        .WIDTH(64), .HEIGHT(64), .IN_CH(32), .MID_CH(64), .OUT_CH(64),
        .LAYER_A(4), .LAYER_B(5), .PE(2), .FIFO_DEPTH(1024)
    ) u (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_pixel_last, .out_last,
        .busy, .done, .fifo_overflow
    );
endmodule
