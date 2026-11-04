`timescale 1ns/1ps
module camus_unet_pl_top_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic in_valid = 1'b0;
    logic signed [31:0] in_data = '0;
    logic in_ready, out_valid, busy, done;
    logic signed [31:0] out_data;

    camus_unet_pl_top #(.WIDTH(16), .FRAME_TOKENS(16)) dut (
        .clk, .rst, .start, .in_valid, .in_data,
        .in_ready, .out_valid, .out_data, .busy, .done);

    integer i;
    logic done_seen = 1'b0;
    always @(posedge clk) if (done) done_seen <= 1'b1;
    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            in_valid <= 1'b1;
            in_data <= {8'(i+3), 8'(i+2), 8'(i+1), 8'(i)};
        end
        @(posedge clk); in_valid <= 1'b0;
        repeat (40) @(posedge clk);
        if (!done_seen) $fatal(1, "CAMUS full topology did not complete");
        $display("CAMUS full topology smoke PASS");
        $finish;
    end
endmodule
