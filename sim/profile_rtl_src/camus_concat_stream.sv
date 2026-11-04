// Synchronous two-stream concatenation. The layer scheduler guarantees that
// both streams describe the same raster position and arrive together.
module camus_concat_stream #(
    parameter integer A_CHANNELS = 16,
    parameter integer B_CHANNELS = 16,
    parameter integer DATA_W = 8
) (
    input logic clk,
    input logic rst,
    input logic a_valid,
    input logic signed [A_CHANNELS*DATA_W-1:0] a_data,
    input logic b_valid,
    input logic signed [B_CHANNELS*DATA_W-1:0] b_data,
    input logic in_last,
    output logic a_ready,
    output logic b_ready,
    output logic out_valid,
    output logic signed [(A_CHANNELS+B_CHANNELS)*DATA_W-1:0] out_data,
    output logic out_last
);
    assign a_ready = b_valid;
    assign b_ready = a_valid;
    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 0;
            out_data <= '0;
            out_last <= 0;
        end else begin
            out_valid <= a_valid && b_valid;
            out_data <= {a_data, b_data};
            out_last <= (a_valid && b_valid) ? in_last : 1'b0;
        end
    end
endmodule
