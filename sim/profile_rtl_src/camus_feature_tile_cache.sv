`timescale 1ns/1ps

// AXI4-Stream 128-bit loader plus two-bank 64-bit SIMD8 feature cache.
// The compute side can read one word per cycle from one bank while DMA fills
// the other. The scheduler is responsible for selecting opposite banks.
module camus_feature_tile_cache #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic clk,
    input  logic rst,

    input  logic load_start,
    input  logic [ADDR_W:0] load_words,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tlast,
    output logic load_done,
    output logic load_busy,
    output logic loaded_bank,

    input  logic read_enable,
    input  logic read_bank,
    input  logic [ADDR_W-1:0] read_address,
    output logic [63:0] read_data,
    output logic read_valid,

    output logic [1:0] bank_ready,
    output logic error
);
    logic tile_wr_start, tile_wr_valid, tile_wr_ready, tile_wr_last;
    logic tile_wr_done, tile_wr_busy, tile_wr_bank;
    logic signed [63:0] tile_wr_data;
    logic tile_active_bank, tile_overflow;
    logic signed [63:0] tile_read_data;

    logic beat_valid;
    logic beat_upper;
    logic [127:0] beat_data;
    logic [15:0] beat_keep;
    logic beat_last;
    logic [ADDR_W:0] words_written;
    logic [ADDR_W:0] load_words_reg;
    logic invalid_keep;
    logic active_load_bank;

    assign tile_wr_start = load_start && !load_busy;
    assign s_axis_tready = load_busy && !beat_valid;
    assign tile_wr_valid = beat_valid && tile_wr_ready;
    assign tile_wr_data = beat_upper ? beat_data[127:64] : beat_data[63:0];
    assign tile_wr_last = words_written == load_words_reg - 1'b1;
    assign invalid_keep = beat_upper
        ? beat_keep[15:8] != 8'hff : beat_keep[7:0] != 8'hff;
    assign read_data = tile_read_data;

    camus_tile_pingpong #(
        .DATA_W(64),
        .DEPTH(DEPTH),
        .ADDR_W(ADDR_W)
    ) u_tile (
        .clk(clk), .rst(rst),
        .wr_start(tile_wr_start), .wr_valid(tile_wr_valid),
        .wr_ready(tile_wr_ready), .wr_data(tile_wr_data),
        .wr_last(tile_wr_last), .wr_done(tile_wr_done),
        .bank_ready(bank_ready), .wr_busy(tile_wr_busy), .wr_bank(tile_wr_bank),
        .rd_en(read_enable), .rd_bank(read_bank), .rd_addr(read_address),
        .rd_data(tile_read_data), .rd_valid(read_valid),
        .swap_bank(1'b0), .active_bank(tile_active_bank),
        .overflow(tile_overflow)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            load_done <= 1'b0;
            load_busy <= 1'b0;
            loaded_bank <= 1'b0;
            active_load_bank <= 1'b0;
            beat_valid <= 1'b0;
            beat_upper <= 1'b0;
            beat_data <= '0;
            beat_keep <= '0;
            beat_last <= 1'b0;
            words_written <= '0;
            load_words_reg <= '0;
            error <= 1'b0;
        end else begin
            load_done <= 1'b0;

            if (load_start && load_busy)
                error <= 1'b1;

            if (load_start && !load_busy) begin
                if (load_words == 0 || load_words > DEPTH) begin
                    error <= 1'b1;
                end else begin
                    load_busy <= 1'b1;
                    active_load_bank <= tile_wr_bank;
                    load_words_reg <= load_words;
                    words_written <= 0;
                    beat_valid <= 1'b0;
                    beat_upper <= 1'b0;
                    error <= 1'b0;
                end
            end

            if (s_axis_tvalid && s_axis_tready) begin
                beat_valid <= 1'b1;
                beat_upper <= 1'b0;
                beat_data <= s_axis_tdata;
                beat_keep <= s_axis_tkeep;
                beat_last <= s_axis_tlast;
            end

            if (tile_wr_valid) begin
                if (invalid_keep)
                    error <= 1'b1;
                words_written <= words_written + 1'b1;
                if (tile_wr_last) begin
                    beat_valid <= 1'b0;
                    beat_upper <= 1'b0;
                    if (!beat_last)
                        error <= 1'b1;
                end else if (!beat_upper) begin
                    beat_upper <= 1'b1;
                end else begin
                    beat_valid <= 1'b0;
                    beat_upper <= 1'b0;
                    if (beat_last)
                        error <= 1'b1;
                end
            end

            if (tile_wr_done) begin
                load_busy <= 1'b0;
                load_done <= 1'b1;
                loaded_bank <= active_load_bank;
            end

            if (tile_overflow)
                error <= 1'b1;
        end
    end
endmodule
