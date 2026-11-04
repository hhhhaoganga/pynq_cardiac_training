`timescale 1ns/1ps

// Same capacity and 64-bit word addresses as the SIMD8 cache, with a
// 128-bit physical read. Paired input groups always start at even addresses.
module camus_feature_tile_cache16 #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_W = $clog2(DEPTH)
) (
    input logic clk, rst, load_start,
    input logic [ADDR_W:0] load_words,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic [127:0] s_axis_tdata,
    input logic [15:0] s_axis_tkeep,
    input logic s_axis_tlast,
    output logic load_done, load_busy, loaded_bank,
    input logic read_enable, read_bank,
    input logic [ADDR_W-1:0] read_address,
    output logic [127:0] read_data,
    output logic read_valid,
    output logic [1:0] bank_ready,
    output logic error
);
    logic tile_ready, tile_done, tile_busy, tile_bank, tile_overflow;
    logic active_bank_unused, active_load_bank, odd_read;
    logic [127:0] tile_data, write_data;
    logic [ADDR_W:0] written, words_reg;
    logic start_ok, write_fire, write_last;

    assign start_ok = load_start && !load_busy && load_words != 0 && load_words <= DEPTH;
    assign s_axis_tready = load_busy && tile_ready;
    assign write_fire = s_axis_tvalid && s_axis_tready;
    assign write_last = written + 2 >= words_reg;
    assign write_data = (written + 1 == words_reg)
        ? {64'd0, s_axis_tdata[63:0]} : s_axis_tdata;
    assign read_data = odd_read ? {64'd0, tile_data[127:64]} : tile_data;

    camus_tile_pingpong #(.DATA_W(128), .DEPTH(DEPTH/2), .ADDR_W(ADDR_W-1)) u_tile (
        .clk, .rst, .wr_start(start_ok), .wr_valid(write_fire),
        .wr_ready(tile_ready), .wr_data(write_data), .wr_last(write_last),
        .wr_done(tile_done), .bank_ready, .wr_busy(tile_busy), .wr_bank(tile_bank),
        .rd_en(read_enable), .rd_bank(read_bank), .rd_addr(read_address[ADDR_W-1:1]),
        .rd_data(tile_data), .rd_valid(read_valid),
        .swap_bank(1'b0), .active_bank(active_bank_unused), .overflow(tile_overflow)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            load_done <= 0;
            load_busy <= 0;
            loaded_bank <= 0;
            active_load_bank <= 0;
            odd_read <= 0;
            written <= 0;
            words_reg <= 0;
            error <= 0;
        end else begin
            load_done <= 0;
            if (read_enable) odd_read <= read_address[0];
            if (load_start) begin
                if (!start_ok) error <= 1;
                else begin
                    load_busy <= 1;
                    active_load_bank <= tile_bank;
                    written <= 0;
                    words_reg <= load_words;
                    error <= 0;
                end
            end
            if (write_fire) begin
                written <= written + 2;
                if (s_axis_tkeep[7:0] != 8'hff
                    || (written + 1 < words_reg && s_axis_tkeep[15:8] != 8'hff)
                    || s_axis_tlast != write_last)
                    error <= 1;
            end
            if (tile_done) begin
                load_busy <= 0;
                load_done <= 1;
                loaded_bank <= active_load_bank;
            end
            if (tile_overflow) error <= 1;
        end
    end
endmodule
