`timescale 1ns/1ps
// Encoder stage 1 plus 2x2 max-pool.  The convolution chain emits one
// complete 16-channel pixel per cycle when available; the pool keeps the
// raster order and emits WIDTH/2 x HEIGHT/2 vectors.
module camus_enc12_pool_chain #(
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
    output logic signed [127:0] out_data,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic fifo_overflow
);
    logic conv_valid, conv_pixel_last, conv_last, conv_busy, conv_done;
    logic signed [15:0] conv_data;
    logic repack_valid;
    logic signed [127:0] repack_data;
    integer repack_pixels;
    wire repack_pixel_last = repack_valid && (repack_pixels == WIDTH*HEIGHT-1);

    camus_enc12_same_chain #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .PE(PE), .FIFO_DEPTH(FIFO_DEPTH)
    ) conv_chain (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(conv_valid), .out_data(conv_data),
        .out_pixel_last(conv_pixel_last), .out_last(conv_last),
        .busy(conv_busy), .done(conv_done), .fifo_overflow
    );

    camus_feature_repacker #(.PE(PE), .OUT_CH(16)) repack2 (
        .clk, .rst, .in_valid(conv_valid), .in_data(conv_data),
        .in_pixel_last(conv_pixel_last), .out_valid(repack_valid),
        .out_data(repack_data), .busy()
    );

    camus_pool2x2_stream #(.WIDTH(WIDTH), .CHANNELS(16)) pool (
        .clk, .rst,
        .in_valid(repack_valid), .in_data(repack_data),
        .in_last(repack_pixel_last), .in_ready(),
        .out_valid, .out_data, .out_last
    );

    assign busy = conv_busy || out_valid;
    assign done = out_valid && out_last;

    always_ff @(posedge clk) begin
        if (rst) begin
            repack_pixels <= 0;
        end else begin
            if (repack_valid) begin
                if (repack_pixels == WIDTH*HEIGHT-1) begin
                    repack_pixels <= 0;
                end else begin
                    repack_pixels <= repack_pixels + 1;
                end
            end
        end
    end
endmodule
