// Streaming 2x2 max-pool for a fixed raster width. One channel vector is
// accepted per cycle; output is produced at even row/even column positions.
module camus_pool2x2_stream #(
    parameter integer WIDTH = 64,
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
    logic signed [CHANNELS*DATA_W-1:0] linebuf [0:WIDTH-1];
    logic signed [CHANNELS*DATA_W-1:0] left_cur;
    logic signed [CHANNELS*DATA_W-1:0] pair_up_reg, pair_cur_reg;
    logic pool_pending;
    logic pending_last;
    integer col;
    integer row;
    integer c;
    logic signed [DATA_W-1:0] v0, v1, v2, v3;
    logic signed [DATA_W-1:0] pair_up, pair_cur, vmax;
    assign in_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            col <= 0;
            row <= 0;
            out_valid <= 0;
            out_data <= '0;
            out_last <= 0;
            left_cur <= '0;
            pair_up_reg <= '0;
            pair_cur_reg <= '0;
            pool_pending <= 0;
            pending_last <= 0;
        end else begin
            out_valid <= 0;
            out_last <= 0;

            // Second comparison stage.  Registering the two pairwise maxima
            // removes the previous line-buffer-to-four-way-compare path.
            if (pool_pending) begin
                for (c = 0; c < CHANNELS; c = c + 1) begin
                    pair_up = pair_up_reg[c*DATA_W +: DATA_W];
                    pair_cur = pair_cur_reg[c*DATA_W +: DATA_W];
                    vmax = (pair_up > pair_cur) ? pair_up : pair_cur;
                    out_data[c*DATA_W +: DATA_W] <= vmax;
                end
                out_valid <= 1;
                out_last <= pending_last;
                pool_pending <= 0;
            end

            if (in_valid) begin
                if ((row[0] == 1'b1) && (col[0] == 1'b1)) begin
                    for (c = 0; c < CHANNELS; c = c + 1) begin
                        v0 = linebuf[col][c*DATA_W +: DATA_W];
                        v1 = linebuf[(col == 0) ? 0 : col-1][c*DATA_W +: DATA_W];
                        v2 = left_cur[c*DATA_W +: DATA_W];
                        v3 = in_data[c*DATA_W +: DATA_W];
                        pair_up_reg[c*DATA_W +: DATA_W] <= (v0 > v1) ? v0 : v1;
                        pair_cur_reg[c*DATA_W +: DATA_W] <= (v2 > v3) ? v2 : v3;
                    end
                    pool_pending <= 1;
                    pending_last <= in_last;
                end
                linebuf[col] <= in_data;
                left_cur <= in_data;
                if (col == WIDTH-1) begin
                    col <= 0;
                    row <= row + 1;
                end else begin
                    col <= col + 1;
                end
            end
        end
    end
endmodule
