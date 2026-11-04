`timescale 1ns/1ps
module camus_conv_requant_relu_tb;
    localparam integer PE = 2;
    localparam integer SIMD = 2;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic enable = 1'b0;
    logic first = 1'b0;
    logic last = 1'b0;
    logic signed [SIMD*8-1:0] activations;
    logic signed [PE*SIMD*8-1:0] weights;
    logic signed [PE*32-1:0] bias;
    logic signed [PE*32-1:0] requant_mult;
    logic signed [PE*7-1:0] requant_shift;
    logic relu_enable = 1'b1;
    logic ready, valid;
    logic signed [PE*8-1:0] outputs;

    always #5 clk = ~clk;

    camus_conv_requant_relu #(.PE(PE), .SIMD(SIMD)) dut (
        .clk, .rst, .enable, .first, .last, .activations, .weights,
        .bias, .requant_mult, .requant_shift, .relu_enable,
        .ready, .valid, .outputs
    );

    task automatic drive_token(
        input logic signed [15:0] a,
        input logic signed [31:0] w,
        input logic f,
        input logic l
    );
        begin
            @(negedge clk);
            activations = a;
            weights = w;
            first = f;
            last = l;
            enable = 1'b1;
            @(negedge clk);
            enable = 1'b0;
            first = 1'b0;
            last = 1'b0;
        end
    endtask

    initial begin
        bias = {-32'sd2, 32'sd1};
        requant_mult = {32'sd1, 32'sd1};
        requant_shift = '0;
        activations = '0;
        weights = '0;
        repeat (2) @(posedge clk);
        rst = 1'b0;

        // Flat packing is [PE0/SIMD0, PE0/SIMD1, PE1/SIMD0, PE1/SIMD1].
        drive_token({-8'sd2, 8'sd1}, {8'sd4, -8'sd1, 8'sd3, 8'sd2}, 1'b1, 1'b0);
        drive_token({8'sd1, 8'sd3}, {8'sd1, -8'sd2, 8'sd2, 8'sd1}, 1'b0, 1'b1);

        repeat (3) @(posedge clk);
        #1;
        if (!valid || outputs[7:0] !== 8'sd2 || outputs[15:8] !== 8'sd0) begin
            $display("CAMUS RTL conv test FAIL valid=%0d outputs=%0d,%0d", valid, $signed(outputs[7:0]), $signed(outputs[15:8]));
            $finish(1);
        end
        $display("CAMUS RTL conv test PASS outputs=%0d,%0d", $signed(outputs[7:0]), $signed(outputs[15:8]));
        $finish(0);
    end
endmodule
