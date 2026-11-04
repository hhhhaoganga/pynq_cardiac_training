`timescale 1ns/1ps
// Streaming INT8 convolution tile for the CAMUS RTL path.
//
// One accepted token contains SIMD input activations and PE*SIMD weights.
// TOKENS tokens form one output pixel for PE output channels. The external
// window/channel scheduler supplies the 3x3 patch order and asserts last on
// the final token. Accumulation is INT32; requantization uses a signed integer
// multiplier followed by an arithmetic shift, then optional ReLU and INT8
// saturation. The structure is deliberately compatible with FINN-style MVU
// folding while keeping the quantization contract explicit.
module camus_conv_requant_relu #(
    parameter integer PE = 4,
    parameter integer SIMD = 4,
    parameter integer ACT_W = 8,
    parameter integer WEIGHT_W = 8,
    parameter integer ACC_W = 32,
    parameter integer MULT_W = 32,
    parameter integer SHIFT_W = 7
) (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    input  logic first,
    input  logic last,
    input  logic signed [SIMD*ACT_W-1:0] activations,
    input  logic signed [PE*SIMD*WEIGHT_W-1:0] weights,
    input  logic signed [PE*ACC_W-1:0] bias,
    input  logic signed [PE*MULT_W-1:0] requant_mult,
    input  logic signed [PE*SHIFT_W-1:0] requant_shift,
    input  logic relu_enable,
    output logic ready,
    output logic valid,
    output logic signed [PE*ACT_W-1:0] outputs
);
    `include "camus_quant_math.svh"

    logic signed [ACC_W-1:0] accum [0:PE-1];
    logic signed [ACC_W-1:0] current_product [0:PE-1];
    logic signed [ACC_W-1:0] final_accum [0:PE-1];
    logic signed [MULT_W-1:0] final_mult [0:PE-1];
    logic signed [SHIFT_W-1:0] final_shift [0:PE-1];
    logic final_relu;
    logic pending_requant;
    logic signed [63:0] scaled_reg [0:PE-1];
    logic signed [31:0] requant_reg [0:PE-1];
    logic signed [SHIFT_W-1:0] scale_shift_reg [0:PE-1];
    logic scale_relu_reg;
    logic scale_pending;
    logic requant_pending;
    integer p, s;
    logic signed [ACT_W-1:0] a;
    logic signed [WEIGHT_W-1:0] w;
    logic signed [ACC_W-1:0] product;
    logic signed [63:0] scaled;
    logic signed [31:0] requant_value;

    assign ready = enable;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= 1'b0;
            pending_requant <= 1'b0;
            scale_pending <= 1'b0;
            requant_pending <= 1'b0;
            outputs <= '0;
            for (p = 0; p < PE; p = p + 1)
                accum[p] <= '0;
        end else begin
            valid <= 1'b0;

            // Requantization is split into three registered stages. This
            // keeps the 32-bit scale multiply, arithmetic shift, and output
            // saturation out of one long accumulator-to-output path.
            if (requant_pending) begin
                for (p = 0; p < PE; p = p + 1) begin
                    outputs[p*ACT_W +: ACT_W] <= camus_sat_relu8(requant_reg[p], scale_relu_reg);
                end
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

            if (enable) begin
                for (p = 0; p < PE; p = p + 1) begin
                    current_product[p] = '0;
                    for (s = 0; s < SIMD; s = s + 1) begin
                        a = activations[s*ACT_W +: ACT_W];
                        w = weights[(p*SIMD+s)*WEIGHT_W +: WEIGHT_W];
                        current_product[p] = current_product[p] + a * w;
                    end
                    if (first)
                        accum[p] <= bias[p*ACC_W +: ACC_W] + current_product[p];
                    else
                        accum[p] <= accum[p] + current_product[p];
                end

                if (last) begin
                    // Include the current token and register the result for
                    // the requantization stage above.
                    for (p = 0; p < PE; p = p + 1) begin
                        final_accum[p] <= first
                            ? (bias[p*ACC_W +: ACC_W] + current_product[p])
                            : (accum[p] + current_product[p]);
                        final_mult[p] <= requant_mult[p*MULT_W +: MULT_W];
                        final_shift[p] <= requant_shift[p*SHIFT_W +: SHIFT_W];
                    end
                    final_relu <= relu_enable;
                    pending_requant <= 1'b1;
                end
            end
        end
    end
endmodule
