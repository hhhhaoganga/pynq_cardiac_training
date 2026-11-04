`timescale 1ns/1ps
module camus_feature_repacker_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;
    logic in_valid = 0;
    logic signed [15:0] in_data;
    logic in_pixel_last = 0;
    logic out_valid, busy;
    logic signed [127:0] out_data;
    integer g, i;
    camus_feature_repacker dut(.clk, .rst, .in_valid, .in_data,
        .in_pixel_last, .out_valid, .out_data, .busy);
    initial begin
        repeat (2) @(posedge clk);
        rst <= 0;
        for (g = 0; g < 8; g = g + 1) begin
            @(negedge clk);
            in_data <= {8'(g*2+1), 8'(g*2)};
            in_pixel_last <= (g == 7);
            in_valid <= 1;
            @(negedge clk);
            in_valid <= 0;
            in_pixel_last <= 0;
        end
        @(posedge clk);
        if (!out_valid) $fatal(1, "repacker did not emit a pixel");
        for (i = 0; i < 16; i = i + 1)
            if ($signed(out_data[i*8 +: 8]) !== i)
                $fatal(1, "repacker lane %0d got %0d", i, $signed(out_data[i*8 +: 8]));
        $display("CAMUS feature repacker PASS");
        $finish;
    end
endmodule
