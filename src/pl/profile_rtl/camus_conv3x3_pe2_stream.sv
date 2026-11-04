`timescale 1ns/1ps
// Real first-layer 3x3 streaming scheduler for the PE2 RTL path.
// Input is one 3-channel pixel per cycle in raster order. Two line buffers
// form a valid 3x3 window; output channels are folded in groups of two and
// the existing PE2 Conv/Requant/ReLU tile performs the MAC and requantization.
module camus_conv3x3_pe2_stream #(
    parameter integer WIDTH = 256,
    parameter integer PE = 2,
    parameter integer SIMD = 4,
    parameter integer IN_CH = 3,
    parameter integer OUT_CH = 16
) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    input logic signed [IN_CH*8-1:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [PE*8-1:0] out_data,
    output logic out_last,
    output logic busy
);
    `include "camus_enc1_weights.svh"
    localparam integer POS = IN_CH*9;
    localparam integer GROUPS = (OUT_CH+PE-1)/PE;
    localparam integer TOKENS = (POS+SIMD-1)/SIMD;

    (* ram_style = "block" *) logic signed [IN_CH*8-1:0] line1 [0:WIDTH-1];
    (* ram_style = "block" *) logic signed [IN_CH*8-1:0] line2 [0:WIDTH-1];
    logic signed [IN_CH*8-1:0] row1_l1, row1_l2, row2_l1, row2_l2;
    logic signed [IN_CH*8-1:0] cur_l1, cur_l2;
    logic signed [7:0] window [0:POS-1];
    integer col, row, c, c_comb, i, j;

    typedef enum logic [1:0] {S_IDLE, S_MAC, S_WAIT} state_t;
    state_t state;
    integer group_idx, token_idx;
    logic signed [SIMD*8-1:0] tile_a_next, tile_a_reg;
    logic signed [PE*SIMD*8-1:0] tile_w_next, tile_w_reg;
    logic signed [PE*32-1:0] tile_bias_next, tile_bias_reg;
    logic signed [PE*32-1:0] tile_mult_next, tile_mult_reg;
    logic signed [PE*7-1:0] tile_shift_next, tile_shift_reg;
    logic tile_v_next, tile_v_reg, tile_first_next, tile_first_reg;
    logic tile_last_next, tile_last_reg;
    logic signed [PE*8-1:0] tile_out;
    logic tile_v_out;
    logic pending_group_valid;
    integer oc, pos;

    assign in_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE);

    camus_conv_requant_relu_macpipe #(.PE(PE), .SIMD(SIMD)) u_tile (
        .clk(clk), .rst(rst), .enable(tile_v_reg), .first(tile_first_reg),
        .last(tile_last_reg), .activations(tile_a_reg), .weights(tile_w_reg),
        .bias(tile_bias_reg), .requant_mult(tile_mult_reg),
        .requant_shift(tile_shift_reg), .relu_enable(1'b1), .ready(),
        .valid(tile_v_out), .outputs(tile_out)
    );

    integer c_next, lane_next;
    always_comb begin
        tile_a_next = '0;
        tile_w_next = '0;
        tile_bias_next = '0;
        tile_mult_next = '0;
        tile_shift_next = '0;
        tile_v_next = (state == S_MAC);
        tile_first_next = (token_idx == 0);
        tile_last_next = (token_idx == TOKENS-1);
        for (c_next = 0; c_next < PE; c_next = c_next + 1) begin
            oc = group_idx*PE + c_next;
            tile_bias_next[c_next*32 +: 32] = (oc < OUT_CH) ? CAMUS_ENC1_B[oc] : '0;
            tile_mult_next[c_next*32 +: 32] = (oc < OUT_CH) ? CAMUS_ENC1_RM[oc] : '0;
            tile_shift_next[c_next*7 +: 7] = (oc < OUT_CH) ? CAMUS_ENC1_RS[oc][6:0] : '0;
        end
        for (i = 0; i < SIMD; i = i + 1) begin
            pos = token_idx*SIMD + i;
            if (pos < POS) begin
                tile_a_next[i*8 +: 8] = window[pos];
                for (c_next = 0; c_next < PE; c_next = c_next + 1)
                    tile_w_next[(c_next*SIMD+i)*8 +: 8] = CAMUS_ENC1_TILE_W[group_idx][token_idx][c_next*SIMD+i];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            col <= 0;
            row <= 0;
            group_idx <= 0;
            token_idx <= 0;
            out_valid <= 1'b0;
            out_last <= 1'b0;
            out_data <= '0;
            pending_group_valid <= 1'b0;
            tile_v_reg <= 1'b0;
            tile_first_reg <= 1'b0;
            tile_last_reg <= 1'b0;
            tile_a_reg <= '0;
            tile_w_reg <= '0;
            tile_bias_reg <= '0;
            tile_mult_reg <= '0;
            tile_shift_reg <= '0;
            row1_l1 <= '0; row1_l2 <= '0;
            row2_l1 <= '0; row2_l2 <= '0;
            cur_l1 <= '0; cur_l2 <= '0;
            // Line RAMs are not reset. The scheduler suppresses output for
            // the first two rows, by which time every address has been
            // initialized by the incoming raster stream.
        end else begin
            out_valid <= 1'b0;
            out_last <= 1'b0;

            // One register stage isolates ROM/window address generation from
            // the DSP input path. This is essential once real weights are
            // selected dynamically for each folded group and token.
            tile_v_reg <= tile_v_next;
            tile_first_reg <= tile_first_next;
            tile_last_reg <= tile_last_next;
            tile_a_reg <= tile_a_next;
            tile_w_reg <= tile_w_next;
            tile_bias_reg <= tile_bias_next;
            tile_mult_reg <= tile_mult_next;
            tile_shift_reg <= tile_shift_next;

            if (tile_v_out) begin
                out_valid <= 1'b1;
                out_data <= tile_out;
                out_last <= pending_group_valid && (group_idx == GROUPS-1);
                pending_group_valid <= 1'b0;
                if (group_idx == GROUPS-1) begin
                    state <= S_IDLE;
                    group_idx <= 0;
                    token_idx <= 0;
                end else begin
                    group_idx <= group_idx + 1;
                    token_idx <= 0;
                    state <= S_MAC;
                end
            end

            if (state == S_IDLE && in_valid) begin
                if (col == 0) begin
                    row1_l1 <= '0; row1_l2 <= '0;
                    row2_l1 <= '0; row2_l2 <= '0;
                    cur_l1 <= '0; cur_l2 <= '0;
                end
                for (c = 0; c < IN_CH; c = c + 1) begin
                    window[c*9+0] <= row2_l2[c*8 +: 8];
                    window[c*9+1] <= row2_l1[c*8 +: 8];
                    window[c*9+2] <= line2[col][c*8 +: 8];
                    window[c*9+3] <= row1_l2[c*8 +: 8];
                    window[c*9+4] <= row1_l1[c*8 +: 8];
                    window[c*9+5] <= line1[col][c*8 +: 8];
                    window[c*9+6] <= cur_l2[c*8 +: 8];
                    window[c*9+7] <= cur_l1[c*8 +: 8];
                    window[c*9+8] <= in_pixel[c*8 +: 8];
                end
                line2[col] <= line1[col];
                line1[col] <= in_pixel;
                row2_l2 <= row2_l1; row2_l1 <= line2[col];
                row1_l2 <= row1_l1; row1_l1 <= line1[col];
                cur_l2 <= cur_l1; cur_l1 <= in_pixel;
                if (row >= 2 && col >= 2) begin
                    state <= S_MAC;
                    group_idx <= 0;
                    token_idx <= 0;
                end
                if (col == WIDTH-1) begin
                    col <= 0;
                    row <= row + 1;
                end else begin
                    col <= col + 1;
                end
            end else if (state == S_MAC) begin
                if (token_idx == TOKENS-1) begin
                    pending_group_valid <= 1'b1;
                    state <= S_WAIT;
                end else begin
                    token_idx <= token_idx + 1;
                end
            end
        end
    end
endmodule
