`timescale 1ns/1ps
module camus_enc12_same_chain_tb;
    localparam integer W = 5;
    localparam integer H = 4;
    localparam integer TOTAL = W*H*8;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1, start = 1'b0, in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, out_valid, out_pixel_last, out_last, busy, done, fifo_overflow;
    logic signed [15:0] out_data;
    integer y, x, ch, outputs, pixels, frames;

    camus_enc12_same_chain #(.WIDTH(W), .HEIGHT(H), .FIFO_DEPTH(128)) dut (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_pixel_last, .out_last, .busy, .done,
        .fifo_overflow);

    always @(posedge clk) begin
        if (out_valid) begin
            outputs = outputs + 1;
            if (out_pixel_last) pixels = pixels + 1;
            if (out_last) frames = frames + 1;
        end
    end

    initial begin
        outputs = 0; pixels = 0; frames = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                @(negedge clk);
                for (ch = 0; ch < 3; ch = ch + 1)
                    in_pixel[ch*8 +: 8] = $signed((y + 3) * (x + 1) + ch - 12);
                in_valid <= 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (in_ready) break;
                end
                @(negedge clk); in_valid <= 1'b0;
            end
        end
        repeat (100000) @(posedge clk);
        if (fifo_overflow)
            $fatal(1, "encoder pixel FIFO overflowed");
        if (outputs != TOTAL)
            $fatal(1, "encoder output count mismatch got=%0d expected=%0d", outputs, TOTAL);
        if (pixels != W*H)
            $fatal(1, "encoder pixel boundary mismatch got=%0d expected=%0d", pixels, W*H);
        if (frames != 1)
            $fatal(1, "encoder frame boundary mismatch got=%0d expected=1", frames);
        $display("CAMUS enc12 same-padding chain PASS outputs=%0d pixels=%0d", outputs, pixels);
        $finish;
    end
endmodule
