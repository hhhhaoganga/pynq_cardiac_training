`timescale 1ns/1ps
// Small elastic FIFO used between folded convolution layers.  Full-frame
// deployment will replace this with a BRAM/DDR tile queue; the interface is
// intentionally AXI-stream-like so that replacement is local.
module camus_feature_fifo #(
    parameter integer WIDTH = 128,
    parameter integer DEPTH = 16
) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    output logic in_ready,
    input logic signed [WIDTH-1:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic signed [WIDTH-1:0] out_data,
    output logic overflow
);
    localparam integer PW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    logic signed [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PW-1:0] rd_ptr, wr_ptr;
    integer count;
    assign in_ready = (count < DEPTH) || (out_valid && out_ready);
    assign out_valid = (count != 0);
    assign out_data = mem[rd_ptr];
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr <= '0;
            wr_ptr <= '0;
            count <= 0;
            overflow <= 1'b0;
        end else begin
            if (in_valid && !in_ready) overflow <= 1'b1;
            case ({in_valid && in_ready, out_valid && out_ready})
                2'b10: begin
                    mem[wr_ptr] <= in_data;
                    wr_ptr <= (wr_ptr == DEPTH-1) ? '0 : wr_ptr + 1'b1;
                    count <= count + 1;
                end
                2'b01: begin
                    rd_ptr <= (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1'b1;
                    count <= count - 1;
                end
                2'b11: begin
                    mem[wr_ptr] <= in_data;
                    wr_ptr <= (wr_ptr == DEPTH-1) ? '0 : wr_ptr + 1'b1;
                    rd_ptr <= (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
