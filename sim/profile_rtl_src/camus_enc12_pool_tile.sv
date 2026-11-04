`timescale 1ns/1ps
// Encoder stage 1 + pool + ping-pong tile cache.  The cache write path is
// intentionally independent from the future AXI HP reader so this module
// can be verified entirely on-chip before adding DMA and PS control.
module camus_enc12_pool_tile #(
    parameter integer WIDTH = 256,
    parameter integer HEIGHT = 256,
    parameter integer PE = 2,
    parameter integer FIFO_DEPTH = 1024,
    parameter integer TILE_DEPTH = (WIDTH/2)*(HEIGHT/2)
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic in_valid,
    input logic signed [23:0] in_pixel,
    output logic in_ready,
    output logic busy,
    output logic done,
    output logic fifo_overflow,
    output logic wr_done,
    output logic [1:0] bank_ready,
    output logic wr_bank,
    input logic read_start,
    input logic read_bank,
    input logic [((TILE_DEPTH <= 1) ? 1 : $clog2(TILE_DEPTH))-1:0] read_addr,
    input logic read_en,
    output logic signed [127:0] read_data,
    output logic read_valid,
    output logic cache_overflow
);
    localparam integer ADDR_W = (TILE_DEPTH <= 1) ? 1 : $clog2(TILE_DEPTH);
    logic pool_valid, pool_last, pool_busy, pool_done;
    logic signed [127:0] pool_data;
    logic cache_wr_ready, cache_wr_busy;

    camus_enc12_pool_chain #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .PE(PE), .FIFO_DEPTH(FIFO_DEPTH)
    ) compute (
        .clk, .rst, .start,
        .in_valid, .in_pixel, .in_ready,
        .out_valid(pool_valid), .out_data(pool_data), .out_last(pool_last),
        .busy(pool_busy), .done(pool_done), .fifo_overflow
    );

    camus_tile_pingpong #(.DATA_W(128), .DEPTH(TILE_DEPTH), .ADDR_W(ADDR_W)) cache (
        .clk, .rst,
        .wr_start(start), .wr_valid(pool_valid), .wr_ready(cache_wr_ready),
        .wr_data(pool_data), .wr_last(pool_last), .wr_done,
        .bank_ready, .wr_busy(cache_wr_busy), .wr_bank,
        .rd_en(read_en), .rd_bank(read_bank), .rd_addr(read_addr),
        .rd_data(read_data), .rd_valid(read_valid), .swap_bank(1'b0),
        .active_bank(), .overflow(cache_overflow)
    );

    assign busy = pool_busy || cache_wr_busy || read_valid;
    assign done = pool_done;
endmodule
