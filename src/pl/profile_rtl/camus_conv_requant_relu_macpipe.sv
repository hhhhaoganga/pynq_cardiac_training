`timescale 1ns/1ps
// Two-stage MAC variant for the real 3x3 scheduler.
// Stage 1 registers the SIMD product sum; stage 2 performs the INT32
// accumulation. Requantization remains the three registered stages used by
// camus_conv_requant_relu.
module camus_conv_requant_relu_macpipe #(
    parameter integer PE = 2,
    parameter integer SIMD = 4,
    parameter integer ACT_W = 8,
    parameter integer WEIGHT_W = 8,
    parameter integer ACC_W = 32,
    parameter integer MULT_W = 32,
    parameter integer SHIFT_W = 7
) (
    input logic clk,
    input logic rst,
    input logic enable,
    input logic first,
    input logic last,
    input logic signed [SIMD*ACT_W-1:0] activations,
    input logic signed [PE*SIMD*WEIGHT_W-1:0] weights,
    input logic signed [PE*ACC_W-1:0] bias,
    input logic signed [PE*MULT_W-1:0] requant_mult,
    input logic signed [PE*SHIFT_W-1:0] requant_shift,
    input logic relu_enable,
    output logic ready,
    output logic valid,
    output logic signed [PE*ACT_W-1:0] outputs
);
    // Keep the arithmetic helpers local to this reusable tile.  This avoids
    // tool-dependent include-order behavior in standalone Vivado synthesis.
    function automatic signed [31:0] camus_round_shift(input signed [63:0] value, input integer shift);
        reg signed [63:0] rounded;
        begin
            if (shift <= 0) camus_round_shift = value <<< (-shift);
            else begin
                rounded = value + (64'sd1 <<< (shift - 1));
                camus_round_shift = rounded >>> shift;
            end
        end
    endfunction
    function automatic signed [7:0] camus_sat_relu8(input signed [31:0] value, input logic relu_enable);
        reg signed [31:0] clipped;
        begin
            clipped = value;
            if (relu_enable && clipped < 0) clipped = 0;
            if (clipped > 127) clipped = 127;
            else if (clipped < -128) clipped = -128;
            camus_sat_relu8 = clipped[7:0];
        end
    endfunction
    logic signed [ACC_W-1:0] product_reg [0:PE-1];
    logic signed [ACC_W-1:0] accum [0:PE-1];
    logic signed [ACC_W-1:0] bias_reg [0:PE-1];
    logic signed [MULT_W-1:0] mult_reg [0:PE-1];
    logic signed [SHIFT_W-1:0] shift_reg [0:PE-1];
    logic first_reg, last_reg, relu_reg, prod_valid;
    logic signed [ACC_W-1:0] final_accum [0:PE-1];
    logic signed [MULT_W-1:0] final_mult [0:PE-1];
    logic signed [SHIFT_W-1:0] final_shift [0:PE-1];
    logic final_relu, pending_requant, scale_pending, requant_pending;
    logic signed [63:0] scaled_reg [0:PE-1];
    logic signed [31:0] requant_reg [0:PE-1];
    logic signed [SHIFT_W-1:0] scale_shift_reg [0:PE-1];
    logic scale_relu_reg;
    integer p, s;
    logic signed [ACT_W-1:0] a;
    logic signed [WEIGHT_W-1:0] w;
    logic signed [ACC_W-1:0] prod_calc;
    logic signed [ACC_W-1:0] acc_value;

    assign ready = enable;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= 1'b0;
            prod_valid <= 1'b0;
            pending_requant <= 1'b0;
            scale_pending <= 1'b0;
            requant_pending <= 1'b0;
            outputs <= '0;
            for (p = 0; p < PE; p = p + 1)
                accum[p] <= '0;
        end else begin
            valid <= 1'b0;
            prod_valid <= 1'b0;

            if (requant_pending) begin
                for (p = 0; p < PE; p = p + 1)
                    outputs[p*ACT_W +: ACT_W] <= camus_sat_relu8(requant_reg[p], scale_relu_reg);
                valid <= 1'b1;
                requant_pending <= 1'b0;
            end
            if (scale_pending) begin
                for (p = 0; p < PE; p = p + 1)
                    requant_reg[p] <= camus_round_shift(scaled_reg[p], scale_shift_reg[p]);
                scale_pending <= 1'b0;
                requant_pending <= 1'b1;
            end
            if (pending_requant) begin
                for (p = 0; p < PE; p = p + 1)
                    scaled_reg[p] <= final_accum[p] * final_mult[p];
                for (p = 0; p < PE; p = p + 1)
                    scale_shift_reg[p] <= final_shift[p];
                scale_relu_reg <= final_relu;
                pending_requant <= 1'b0;
                scale_pending <= 1'b1;
            end

            // Stage 2: accumulate the registered SIMD sum.
            if (prod_valid) begin
                for (p = 0; p < PE; p = p + 1) begin
                    acc_value = first_reg ? (bias_reg[p] + product_reg[p])
                                          : (accum[p] + product_reg[p]);
                    accum[p] <= acc_value;
                    if (last_reg) begin
                        final_accum[p] <= acc_value;
                        final_mult[p] <= mult_reg[p];
                        final_shift[p] <= shift_reg[p];
                    end
                end
                if (last_reg) begin
                    final_relu <= relu_reg;
                    pending_requant <= 1'b1;
                end
            end

            // Stage 1: SIMD product sum. This is intentionally separate from
            // the 32-bit accumulator update above.
            if (enable) begin
                for (p = 0; p < PE; p = p + 1) begin
                    prod_calc = '0;
                    for (s = 0; s < SIMD; s = s + 1) begin
                        a = activations[s*ACT_W +: ACT_W];
                        w = weights[(p*SIMD+s)*WEIGHT_W +: WEIGHT_W];
                        prod_calc = prod_calc + a * w;
                    end
                    product_reg[p] <= prod_calc;
                    bias_reg[p] <= bias[p*ACC_W +: ACC_W];
                    mult_reg[p] <= requant_mult[p*MULT_W +: MULT_W];
                    shift_reg[p] <= requant_shift[p*SHIFT_W +: SHIFT_W];
                end
                first_reg <= first;
                last_reg <= last;
                relu_reg <= relu_enable;
                prod_valid <= 1'b1;
            end
        end
    end
endmodule
