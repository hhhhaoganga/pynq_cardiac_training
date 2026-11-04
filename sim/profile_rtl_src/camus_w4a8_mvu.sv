`timescale 1ns/1ps

// W4A8 matrix-vector unit used by both frame-pipeline engines.
// Default shape is PE4 x SIMD8 = 32 MAC/cycle. Activations are unsigned U8;
// each packed weight nibble is signed two's-complement INT4.
module camus_w4a8_mvu #(
    parameter integer PE = 4,
    parameter integer SIMD = 8,
    parameter integer ACC_W = 32,
    parameter integer MULT_W = 32,
    parameter integer SHIFT_W = 7
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    output logic in_ready,
    input  logic first,
    input  logic last,
    input  logic [SIMD*8-1:0] activations_u8,
    input  logic [PE*SIMD*4-1:0] weights_w4,
    input  logic signed [PE*ACC_W-1:0] bias,
    input  logic signed [PE*MULT_W-1:0] requant_mult,
    input  logic signed [PE*SHIFT_W-1:0] requant_shift,
    input  logic relu_enable,
    output logic out_valid,
    output logic [PE*8-1:0] outputs_q8
);
    logic product_valid;
    logic product_first;
    logic product_last;
    logic product_relu;
    logic signed [ACC_W-1:0] product_sum [0:PE-1];
    logic signed [ACC_W-1:0] product_bias [0:PE-1];
    logic signed [MULT_W-1:0] product_mult [0:PE-1];
    logic signed [SHIFT_W-1:0] product_shift [0:PE-1];

    localparam integer LANE_W = 12;
    localparam integer PAIR_W = LANE_W + 1;
    localparam integer QUAD_W = PAIR_W + 1;
    localparam integer OCT_W = QUAD_W + 1;
    localparam integer SUM_W = OCT_W + ((SIMD == 16) ? 1 : 0);

    logic mac_valid;
    logic mac_first;
    logic mac_last;
    logic mac_relu;
    logic signed [LANE_W-1:0] mac_lane_next [0:PE-1][0:SIMD-1];
    logic signed [LANE_W-1:0] mac_lane_reg [0:PE-1][0:SIMD-1];
    logic signed [ACC_W-1:0] mac_bias [0:PE-1];
    logic signed [MULT_W-1:0] mac_mult [0:PE-1];
    logic signed [SHIFT_W-1:0] mac_shift [0:PE-1];

    logic signed [ACC_W-1:0] accumulator [0:PE-1];
    logic rq0_valid, rq0_relu;
    logic signed [ACC_W-1:0] rq0_acc [0:PE-1];
    logic signed [MULT_W-1:0] rq0_mult [0:PE-1];
    logic signed [SHIFT_W-1:0] rq0_shift [0:PE-1];

    logic rq1_valid, rq1_relu;
    logic signed [63:0] rq1_product [0:PE-1];
    logic signed [SHIFT_W-1:0] rq1_shift [0:PE-1];

    logic rq2_valid, rq2_relu;
    logic [63:0] rq2_magnitude [0:PE-1];
    logic signed [SHIFT_W-1:0] rq2_shift [0:PE-1];
    logic rq2_negative [0:PE-1];

    logic rq3_valid, rq3_relu;
    logic [63:0] rq3_rounded [0:PE-1];
    logic signed [SHIFT_W-1:0] rq3_shift [0:PE-1];
    logic rq3_negative [0:PE-1];

    logic rq4_valid, rq4_relu;
    logic [63:0] rq4_shifted [0:PE-1];
    logic rq4_negative [0:PE-1];

    logic rq5_valid, rq5_relu;
    logic signed [31:0] rq5_value [0:PE-1];

    integer p_comb, s_comb;
    integer p_seq, s_seq;
    logic signed [PAIR_W-1:0] mac_pair [0:PE-1][0:SIMD/2-1];
    logic signed [QUAD_W-1:0] mac_quad [0:PE-1][0:SIMD/4-1];
    logic signed [OCT_W-1:0] mac_oct [0:PE-1][0:SIMD/8-1];
    logic signed [SUM_W-1:0] mac_sum [0:PE-1];
    logic signed [ACC_W-1:0] accumulated_value;

    // SIMD8 and SIMD16 keep each tree level at its exact signed
    // width so synthesis does not turn eight INT4 products into a 32-bit
    // carry chain. The lane products are registered before this tree.
    always_comb begin
        for (p_comb = 0; p_comb < PE; p_comb = p_comb + 1) begin
            for (s_comb = 0; s_comb < SIMD; s_comb = s_comb + 1)
                mac_lane_next[p_comb][s_comb] = $signed({1'b0, activations_u8[s_comb*8 +: 8]})
                    * $signed(weights_w4[(p_comb*SIMD+s_comb)*4 +: 4]);
            for (s_comb = 0; s_comb < SIMD/2; s_comb = s_comb + 1)
                mac_pair[p_comb][s_comb] =
                    {mac_lane_reg[p_comb][2*s_comb][LANE_W-1], mac_lane_reg[p_comb][2*s_comb]}
                    + {mac_lane_reg[p_comb][2*s_comb+1][LANE_W-1], mac_lane_reg[p_comb][2*s_comb+1]};
            for (s_comb = 0; s_comb < SIMD/4; s_comb = s_comb + 1)
                mac_quad[p_comb][s_comb] =
                    {mac_pair[p_comb][2*s_comb][PAIR_W-1], mac_pair[p_comb][2*s_comb]}
                    + {mac_pair[p_comb][2*s_comb+1][PAIR_W-1], mac_pair[p_comb][2*s_comb+1]};
            for (s_comb = 0; s_comb < SIMD/8; s_comb = s_comb + 1)
                mac_oct[p_comb][s_comb] =
                    {mac_quad[p_comb][2*s_comb][QUAD_W-1], mac_quad[p_comb][2*s_comb]}
                    + {mac_quad[p_comb][2*s_comb+1][QUAD_W-1], mac_quad[p_comb][2*s_comb+1]};
            if (SIMD == 16)
                mac_sum[p_comb] = {mac_oct[p_comb][0][OCT_W-1], mac_oct[p_comb][0]}
                    + {mac_oct[p_comb][SIMD/8-1][OCT_W-1], mac_oct[p_comb][SIMD/8-1]};
            else
                mac_sum[p_comb] = mac_oct[p_comb][0];
        end
    end

    function automatic [7:0] saturate_q8(
        input signed [31:0] value,
        input logic use_relu
    );
        reg signed [31:0] clipped;
        begin
            clipped = value;
            if (use_relu) begin
                if (clipped < 0)
                    clipped = 0;
                else if (clipped > 255)
                    clipped = 255;
            end else begin
                if (clipped < -127)
                    clipped = -127;
                else if (clipped > 127)
                    clipped = 127;
            end
            saturate_q8 = clipped[7:0];
        end
    endfunction

    // The requant pipeline accepts one completed PE group every cycle, so the
    // MAC input never needs to stop for bias/requant/output work.
    assign in_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            mac_valid <= 1'b0;
            product_valid <= 1'b0;
            rq0_valid <= 1'b0;
            rq1_valid <= 1'b0;
            rq2_valid <= 1'b0;
            rq3_valid <= 1'b0;
            rq4_valid <= 1'b0;
            rq5_valid <= 1'b0;
            out_valid <= 1'b0;
            outputs_q8 <= '0;
            for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1)
                accumulator[p_seq] <= '0;
        end else begin
            mac_valid <= in_valid;
            product_valid <= mac_valid;
            rq0_valid <= 1'b0;
            rq1_valid <= rq0_valid;
            rq2_valid <= rq1_valid;
            rq3_valid <= rq2_valid;
            rq4_valid <= rq3_valid;
            rq5_valid <= rq4_valid;
            out_valid <= rq5_valid;

            if (in_valid) begin
                mac_first <= first;
                mac_last <= last;
                mac_relu <= relu_enable;
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    for (s_seq = 0; s_seq < SIMD; s_seq = s_seq + 1)
                        mac_lane_reg[p_seq][s_seq] <= mac_lane_next[p_seq][s_seq];
                    mac_bias[p_seq] <= bias[p_seq*ACC_W +: ACC_W];
                    mac_mult[p_seq] <= requant_mult[p_seq*MULT_W +: MULT_W];
                    mac_shift[p_seq] <= requant_shift[p_seq*SHIFT_W +: SHIFT_W];
                end
            end

            if (mac_valid) begin
                product_first <= mac_first;
                product_last <= mac_last;
                product_relu <= mac_relu;
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    product_sum[p_seq] <= {{(ACC_W-SUM_W){mac_sum[p_seq][SUM_W-1]}}, mac_sum[p_seq]};
                    product_bias[p_seq] <= mac_bias[p_seq];
                    product_mult[p_seq] <= mac_mult[p_seq];
                    product_shift[p_seq] <= mac_shift[p_seq];
                end
            end

            if (product_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    accumulated_value = product_first
                        ? product_bias[p_seq] + product_sum[p_seq]
                        : accumulator[p_seq] + product_sum[p_seq];
                    accumulator[p_seq] <= accumulated_value;
                    if (product_last) begin
                        rq0_acc[p_seq] <= accumulated_value;
                        rq0_mult[p_seq] <= product_mult[p_seq];
                        rq0_shift[p_seq] <= product_shift[p_seq];
                    end
                end
                if (product_last) begin
                    rq0_valid <= 1'b1;
                    rq0_relu <= product_relu;
                end
            end

            if (rq0_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1)
                    rq1_product[p_seq] <= rq0_acc[p_seq] * rq0_mult[p_seq];
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1)
                    rq1_shift[p_seq] <= rq0_shift[p_seq];
                rq1_relu <= rq0_relu;
            end

            if (rq1_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    rq2_negative[p_seq] <= rq1_product[p_seq] < 0;
                    rq2_magnitude[p_seq] <= (rq1_product[p_seq] < 0)
                        ? -rq1_product[p_seq] : rq1_product[p_seq];
                    rq2_shift[p_seq] <= rq1_shift[p_seq];
                end
                rq2_relu <= rq1_relu;
            end

            if (rq2_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    rq3_rounded[p_seq] <= (rq2_shift[p_seq] > 0)
                        ? rq2_magnitude[p_seq] + (64'd1 << (rq2_shift[p_seq] - 1'b1))
                        : rq2_magnitude[p_seq];
                    rq3_shift[p_seq] <= rq2_shift[p_seq];
                    rq3_negative[p_seq] <= rq2_negative[p_seq];
                end
                rq3_relu <= rq2_relu;
            end

            if (rq3_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1) begin
                    if (rq3_shift[p_seq] > 0)
                        rq4_shifted[p_seq] <= rq3_rounded[p_seq] >> rq3_shift[p_seq];
                    else if (rq3_shift[p_seq] < 0)
                        rq4_shifted[p_seq] <= rq3_rounded[p_seq] << (-rq3_shift[p_seq]);
                    else
                        rq4_shifted[p_seq] <= rq3_rounded[p_seq];
                    rq4_negative[p_seq] <= rq3_negative[p_seq];
                end
                rq4_relu <= rq3_relu;
            end

            if (rq4_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1)
                    rq5_value[p_seq] <= rq4_negative[p_seq]
                        ? -$signed(rq4_shifted[p_seq]) : $signed(rq4_shifted[p_seq]);
                rq5_relu <= rq4_relu;
            end

            if (rq5_valid) begin
                for (p_seq = 0; p_seq < PE; p_seq = p_seq + 1)
                    outputs_q8[p_seq*8 +: 8] <= saturate_q8(rq5_value[p_seq], rq5_relu);
            end
        end
    end
endmodule
