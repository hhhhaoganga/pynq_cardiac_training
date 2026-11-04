`timescale 1ns/1ps
// Collect PE2 folded output groups back into one complete feature vector per
// pixel.  The layer engine emits groups in order and marks the final group
// with pixel_last; this adapter is the bridge to the next layer's raster
// input.  A production frame wrapper will place a FIFO after this block so a
// slow consumer cannot stall the upstream line-buffer scheduler.
module camus_feature_repacker #(
    parameter integer PE = 2,
    parameter integer OUT_CH = 16
) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    input logic signed [PE*8-1:0] in_data,
    input logic in_pixel_last,
    output logic out_valid,
    output logic signed [OUT_CH*8-1:0] out_data,
    output logic busy
);
    localparam integer GROUPS = (OUT_CH + PE - 1) / PE;
    localparam integer GW = (GROUPS <= 1) ? 1 : $clog2(GROUPS);
    logic signed [OUT_CH*8-1:0] accum;
    logic [GW-1:0] group_idx;
    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            accum <= '0;
            group_idx <= '0;
            out_valid <= 1'b0;
            out_data <= '0;
            busy <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) begin
                busy <= 1'b1;
                for (i = 0; i < PE; i = i + 1)
                    if (group_idx*PE+i < OUT_CH)
                        accum[(group_idx*PE+i)*8 +: 8] <= in_data[i*8 +: 8];
                if (in_pixel_last) begin
                    for (i = 0; i < PE; i = i + 1)
                        if (group_idx*PE+i < OUT_CH)
                            out_data[(group_idx*PE+i)*8 +: 8] <= in_data[i*8 +: 8];
                    for (i = 0; i < OUT_CH; i = i + 1)
                        if (i < group_idx*PE)
                            out_data[i*8 +: 8] <= accum[i*8 +: 8];
                    out_valid <= 1'b1;
                    group_idx <= '0;
                    busy <= 1'b0;
                end else begin
                    group_idx <= group_idx + 1'b1;
                end
            end
        end
    end
endmodule
