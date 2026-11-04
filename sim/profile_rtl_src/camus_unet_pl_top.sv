`timescale 1ns/1ps
// CAMUS PE2 full-topology closure shell.
//
// This module deliberately exercises the complete encoder/decoder topology
// (two encoder blocks, bottleneck, two decoder blocks, nearest upsampling,
// skip concatenation and a four-class output split into two PE2 heads).
// The current token scheduler is a small closure harness: it accepts one
// SIMD=4 token at a time and uses one-token convolutions.  The production
// version will replace the token source with the 3x3 line-buffer scheduler
// and load the exported INT8 weights.  Keeping the topology in one top-level
// is useful now for synthesis, routing, fanout and BRAM budgeting.
module camus_unet_pl_top #(
    parameter integer PE = 2,
    parameter integer SIMD = 4,
    parameter integer ACT_W = 8,
    parameter integer WIDTH = 16,
    parameter integer FRAME_TOKENS = WIDTH*WIDTH
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic in_valid,
    input  logic signed [SIMD*ACT_W-1:0] in_data,
    output logic in_ready,
    output logic out_valid,
    output logic signed [4*ACT_W-1:0] out_data,
    output logic busy,
    output logic done
);
    localparam integer VEC_W = PE*ACT_W;
    localparam integer CAT_W = 2*PE*ACT_W;

    logic signed [PE*SIMD*ACT_W-1:0] ones_w;
    logic signed [PE*SIMD*ACT_W-1:0] head1_w;
    logic signed [PE*32-1:0] zero_bias;
    logic signed [PE*32-1:0] unit_mult;
    logic signed [PE*7-1:0] zero_shift;

    // Small constant coefficient bank.  It is intentionally non-zero so
    // Vivado keeps the DSP datapaths in the closure build.
    integer k;
    always_comb begin
        ones_w = '0;
        head1_w = '0;
        zero_bias = '0;
        unit_mult = '0;
        zero_shift = '0;
        for (k = 0; k < PE*SIMD; k = k + 1) begin
            ones_w[k*ACT_W +: ACT_W] = 8'sd1;
            head1_w[k*ACT_W +: ACT_W] = (k[0]) ? -8'sd1 : 8'sd2;
        end
        for (k = 0; k < PE; k = k + 1)
            unit_mult[k*32 +: 32] = 32'sd1;
    end

    logic e1_v, p1_v, e2_v, p2_v, b_v, up1_v, c1_v, d1_v, up2_v, c2_v, d2_v;
    logic h0_v, h1_v;
    logic signed [VEC_W-1:0] e1_data, p1_data, e2_data, p2_data, b_data;
    logic signed [VEC_W-1:0] up1_data, d1_data, up2_data, d2_data;
    logic signed [CAT_W-1:0] c1_data, c2_data;
    logic signed [VEC_W-1:0] h0_data, h1_data;
    logic e1_ready, p1_ready, e2_ready, p2_ready, b_ready;
    logic up1_ready, c1_a_ready, c1_b_ready, d1_ready;
    logic up2_ready, c2_a_ready, c2_b_ready, d2_ready;
    logic h0_ready, h1_ready;

    // The closure harness runs one-token convolutions.  first/last are tied
    // together here; the real 3x3 scheduler will emit a multi-token window.
    wire token_valid = in_valid && busy;
    // The source may only wait for readiness before asserting valid.  The
    // previous version tied readiness to the Conv enable, which in turn was
    // tied to in_valid and created a combinational deadlock in simulation.
    assign in_ready = busy;

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_enc1 (
        .clk(clk), .rst(rst), .enable(token_valid), .first(1'b1), .last(1'b1),
        .activations(in_data), .weights(ones_w), .bias(zero_bias),
        .requant_mult(unit_mult), .requant_shift(zero_shift),
        .relu_enable(1'b1), .ready(e1_ready), .valid(e1_v), .outputs(e1_data));

    camus_pool2x2_stream #(.WIDTH(WIDTH), .CHANNELS(PE)) u_pool1 (
        .clk(clk), .rst(rst), .in_valid(e1_v), .in_data(e1_data),
        .in_last(1'b0), .in_ready(p1_ready), .out_valid(p1_v),
        .out_data(p1_data), .out_last());

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_enc2 (
        .clk(clk), .rst(rst), .enable(p1_v), .first(1'b1), .last(1'b1),
        .activations({{(SIMD*ACT_W-VEC_W){1'b0}}, p1_data}),
        .weights(ones_w), .bias(zero_bias), .requant_mult(unit_mult),
        .requant_shift(zero_shift), .relu_enable(1'b1), .ready(e2_ready),
        .valid(e2_v), .outputs(e2_data));

    camus_pool2x2_stream #(.WIDTH(WIDTH/2), .CHANNELS(PE)) u_pool2 (
        .clk(clk), .rst(rst), .in_valid(e2_v), .in_data(e2_data),
        .in_last(1'b0), .in_ready(p2_ready), .out_valid(p2_v),
        .out_data(p2_data), .out_last());

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_bottleneck (
        .clk(clk), .rst(rst), .enable(p2_v), .first(1'b1), .last(1'b1),
        .activations({{(SIMD*ACT_W-VEC_W){1'b0}}, p2_data}),
        .weights(ones_w), .bias(zero_bias), .requant_mult(unit_mult),
        .requant_shift(zero_shift), .relu_enable(1'b1), .ready(b_ready),
        .valid(b_v), .outputs(b_data));

    camus_nearest1x1_stream #(.CHANNELS(PE)) u_up1 (
        .clk(clk), .rst(rst), .in_valid(b_v), .in_data(b_data),
        .in_last(1'b0), .in_ready(up1_ready), .out_valid(up1_v),
        .out_data(up1_data), .out_last());

    camus_concat_stream #(.A_CHANNELS(PE), .B_CHANNELS(PE)) u_concat1 (
        .clk(clk), .rst(rst), .a_valid(e2_v), .a_data(e2_data),
        .b_valid(up1_v), .b_data(up1_data), .in_last(1'b0),
        .a_ready(c1_a_ready), .b_ready(c1_b_ready), .out_valid(c1_v),
        .out_data(c1_data), .out_last());

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_dec1 (
        .clk(clk), .rst(rst), .enable(c1_v), .first(1'b1), .last(1'b1),
        .activations(c1_data), .weights(ones_w), .bias(zero_bias),
        .requant_mult(unit_mult), .requant_shift(zero_shift),
        .relu_enable(1'b1), .ready(d1_ready), .valid(d1_v), .outputs(d1_data));

    camus_nearest1x1_stream #(.CHANNELS(PE)) u_up2 (
        .clk(clk), .rst(rst), .in_valid(d1_v), .in_data(d1_data),
        .in_last(1'b0), .in_ready(up2_ready), .out_valid(up2_v),
        .out_data(up2_data), .out_last());

    camus_concat_stream #(.A_CHANNELS(PE), .B_CHANNELS(PE)) u_concat2 (
        .clk(clk), .rst(rst), .a_valid(e1_v), .a_data(e1_data),
        .b_valid(up2_v), .b_data(up2_data), .in_last(1'b0),
        .a_ready(c2_a_ready), .b_ready(c2_b_ready), .out_valid(c2_v),
        .out_data(c2_data), .out_last());

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_dec2 (
        .clk(clk), .rst(rst), .enable(c2_v), .first(1'b1), .last(1'b1),
        .activations(c2_data), .weights(ones_w), .bias(zero_bias),
        .requant_mult(unit_mult), .requant_shift(zero_shift),
        .relu_enable(1'b1), .ready(d2_ready), .valid(d2_v), .outputs(d2_data));

    // Two PE2 heads form the four-class output (background/LV/myocardium/LA).
    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_head0 (
        .clk(clk), .rst(rst), .enable(d2_v), .first(1'b1), .last(1'b1),
        .activations({{(SIMD*ACT_W-VEC_W){1'b0}}, d2_data}),
        .weights(ones_w), .bias(zero_bias), .requant_mult(unit_mult),
        .requant_shift(zero_shift), .relu_enable(1'b0), .ready(h0_ready),
        .valid(h0_v), .outputs(h0_data));
    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) u_head1 (
        .clk(clk), .rst(rst), .enable(d2_v), .first(1'b1), .last(1'b1),
        .activations({{(SIMD*ACT_W-VEC_W){1'b0}}, d2_data}),
        .weights(head1_w), .bias(zero_bias), .requant_mult(unit_mult),
        .requant_shift(zero_shift), .relu_enable(1'b0), .ready(h1_ready),
        .valid(h1_v), .outputs(h1_data));

    assign out_valid = h0_v && h1_v;
    assign out_data = {h1_data, h0_data};

    logic [$clog2(FRAME_TOKENS+1)-1:0] token_count;
    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            token_count <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                token_count <= '0;
            end else if (busy && token_valid) begin
                if (token_count == FRAME_TOKENS-1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    token_count <= token_count + 1'b1;
                end
            end
        end
    end
endmodule
