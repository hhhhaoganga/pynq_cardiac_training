`timescale 1ns/1ps
module camus_enc12_pool_chain_tb;
    localparam integer W = 8;
    localparam integer H = 8;
    localparam integer EXPECTED = (W/2)*(H/2);
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1, start = 1'b0, in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, out_valid, out_last, busy, done, fifo_overflow;
    logic signed [127:0] out_data;
    integer y, x, ch, outputs, frames;

    camus_enc12_pool_chain #(.WIDTH(W), .HEIGHT(H), .FIFO_DEPTH(256)) dut (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_last, .busy, .done, .fifo_overflow);

    always @(posedge clk) begin
        if (out_valid) begin
            outputs = outputs + 1;
            if (out_last) frames = frames + 1;
        end
    end

    initial begin
        outputs = 0; frames = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                @(negedge clk);
                for (ch = 0; ch < 3; ch = ch + 1)
                    in_pixel[ch*8 +: 8] = $signed((y + 5) * (x + 1) + ch - 20);
                in_valid <= 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (in_ready) break;
                end
                @(negedge clk); in_valid <= 1'b0;
            end
        end
        repeat (200000) @(posedge clk);
        if (fifo_overflow)
            $fatal(1, "encoder pool FIFO overflowed");
        if (outputs != EXPECTED)
            $fatal(1, "pool output count mismatch got=%0d expected=%0d", outputs, EXPECTED);
        if (frames != 1)
            $fatal(1, "pool frame boundary mismatch got=%0d expected=1", frames);
        $display("CAMUS enc12+pool chain PASS outputs=%0d", outputs);
        $finish;
    end
endmodule
