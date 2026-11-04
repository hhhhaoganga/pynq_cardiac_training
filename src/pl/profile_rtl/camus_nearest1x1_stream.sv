// Fixed 2x nearest-neighbour upsampler. A pixel vector is repeated four times.
module camus_nearest1x1_stream #(
    parameter integer CHANNELS = 16,
    parameter integer DATA_W = 8
) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    input logic signed [CHANNELS*DATA_W-1:0] in_data,
    input logic in_last,
    output logic in_ready,
    output logic out_valid,
    output logic signed [CHANNELS*DATA_W-1:0] out_data,
    output logic out_last
);
    logic signed [CHANNELS*DATA_W-1:0] hold_data;
    logic hold_last;
    logic [1:0] repeat_count;
    assign in_ready = (repeat_count == 0);

    always_ff @(posedge clk) begin
        if (rst) begin
            repeat_count <= 0;
            out_valid <= 0;
            out_data <= '0;
            out_last <= 0;
        end else begin
            out_valid <= 0;
            out_last <= 0;
            if (repeat_count != 0) begin
                out_valid <= 1;
                out_data <= hold_data;
                out_last <= (repeat_count == 1) && hold_last;
                if (repeat_count == 1)
                    repeat_count <= 0;
                else
                    repeat_count <= repeat_count - 1'b1;
            end else if (in_valid) begin
                hold_data <= in_data;
                hold_last <= in_last;
                out_valid <= 1;
                out_data <= in_data;
                repeat_count <= 3;
            end
        end
    end
endmodule
