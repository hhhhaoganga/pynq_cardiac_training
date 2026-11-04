`timescale 1ns/1ps
// Two-bank activation/weight tile cache.  The write side models a DDR/DMA
// tile loader; the registered read side models the shared PE consumer.  RAM
// contents are intentionally not reset so Vivado can infer BRAM18 blocks.
module camus_tile_pingpong #(
    parameter integer DATA_W = 128,
    parameter integer DEPTH = 1024,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input logic clk,
    input logic rst,
    input logic wr_start,
    input logic wr_valid,
    output logic wr_ready,
    input logic signed [DATA_W-1:0] wr_data,
    input logic wr_last,
    output logic wr_done,
    output logic [1:0] bank_ready,
    output logic wr_busy,
    output logic wr_bank,
    input logic rd_en,
    input logic rd_bank,
    input logic [ADDR_W-1:0] rd_addr,
    output logic signed [DATA_W-1:0] rd_data,
    output logic rd_valid,
    input logic swap_bank,
    output logic active_bank,
    output logic overflow
);
    // A single bank-interleaved memory is easier for Vivado to infer as
    // true dual-port BRAM than two memories selected by a runtime branch.
    (* ram_style = "block" *) logic signed [DATA_W-1:0] mem [0:(2*DEPTH)-1];
    logic [ADDR_W-1:0] wr_addr;
    integer wr_count;

    assign wr_ready = wr_busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_addr <= '0;
            wr_count <= 0;
            wr_busy <= 1'b0;
            wr_bank <= 1'b1;
            bank_ready <= 2'b00;
            wr_done <= 1'b0;
            rd_valid <= 1'b0;
            rd_data <= '0;
            active_bank <= 1'b0;
            overflow <= 1'b0;
        end else begin
            wr_done <= 1'b0;
            rd_valid <= 1'b0;

            if (wr_start && !wr_busy) begin
                wr_busy <= 1'b1;
                wr_addr <= '0;
                wr_count <= 0;
                bank_ready[wr_bank] <= 1'b0;
            end

            if (wr_valid && !wr_ready)
                overflow <= 1'b1;

            if (wr_valid && wr_ready) begin
                mem[wr_bank*DEPTH + wr_addr] <= wr_data;
                wr_count <= wr_count + 1;
                if (wr_last || (wr_count == DEPTH-1)) begin
                    wr_busy <= 1'b0;
                    bank_ready[wr_bank] <= 1'b1;
                    wr_done <= 1'b1;
                    wr_addr <= '0;
                    wr_bank <= ~wr_bank;
                end else begin
                    wr_addr <= wr_addr + 1'b1;
                end
            end

            if (rd_en) begin
                rd_data <= mem[rd_bank*DEPTH + rd_addr];
                rd_valid <= 1'b1;
            end

            if (swap_bank && bank_ready[active_bank ^ 1'b1])
                active_bank <= active_bank ^ 1'b1;
        end
    end
endmodule
