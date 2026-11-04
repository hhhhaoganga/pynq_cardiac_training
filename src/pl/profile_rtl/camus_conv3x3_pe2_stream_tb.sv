`timescale 1ns/1ps
module camus_conv3x3_pe2_stream_tb;
    localparam integer W = 5;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, out_valid, out_last, busy;
    logic signed [15:0] out_data;
    integer r, c, outputs;

    camus_conv3x3_pe2_stream #(.WIDTH(W), .OUT_CH(16)) dut (
        .clk, .rst, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_last, .busy);

    always @(posedge clk) if (out_valid) outputs <= outputs + 1;

    initial begin
        outputs = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        for (r = 0; r < W; r = r + 1) begin
            for (c = 0; c < W; c = c + 1) begin
                while (!in_ready) @(posedge clk);
                in_valid <= 1'b1;
                in_pixel <= {8'(r+c+2), 8'(r+1), 8'(c+1)};
                @(posedge clk);
                in_valid <= 1'b0;
            end
        end
        repeat (500) @(posedge clk);
        if (outputs == 0) $fatal(1, "3x3 scheduler produced no output");
        $display("CAMUS 3x3 PE2 scheduler smoke PASS outputs=%0d", outputs);
        $finish;
    end
endmodule
