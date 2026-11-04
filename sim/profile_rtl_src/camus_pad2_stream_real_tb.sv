`timescale 1ns/1ps
module camus_pad2_stream_real_tb;
    localparam integer W = 256;
    localparam integer H = 256;
    localparam integer GROUPS = 8;
    localparam integer PIXELS = W*H;
    localparam integer TOTAL = PIXELS*GROUPS;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, out_valid, out_pixel_last, out_last, busy, done;
    logic signed [15:0] out_data;

    logic [23:0] input_mem [0:PIXELS-1];
    logic [15:0] expected_mem [0:TOTAL-1];
    integer pixel_idx, out_idx, pixel_count, mismatch_count;
    integer first_mismatch;
    logic source_done;

    camus_pad2_stream #(.WIDTH(W), .HEIGHT(H), .IN_CH(3), .OUT_CH(16)) dut (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_pixel_last, .out_last, .busy, .done);

    task automatic send_frame;
        integer i;
        begin
            for (i = 0; i < PIXELS; i = i + 1) begin
                @(negedge clk);
                // The hex generator writes channel order c0c1c2.  The RTL
                // interface uses channel 0 in the least-significant byte.
                in_pixel[7:0]   = input_mem[i][23:16];
                in_pixel[15:8]  = input_mem[i][15:8];
                in_pixel[23:16] = input_mem[i][7:0];
                in_valid = 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (in_ready)
                        break;
                end
                @(negedge clk);
                in_valid = 1'b0;
            end
            source_done = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (out_valid) begin
            if (out_idx < TOTAL && out_data !== expected_mem[out_idx]) begin
                mismatch_count = mismatch_count + 1;
                if (first_mismatch < 0) begin
                    first_mismatch = out_idx;
                    $display("first mismatch beat=%0d rtl=%04x expected=%04x pixel=%0d group=%0d",
                             out_idx, out_data, expected_mem[out_idx],
                             out_idx / GROUPS, out_idx % GROUPS);
                end
            end
            out_idx = out_idx + 1;
            if (out_pixel_last)
                pixel_count = pixel_count + 1;
        end
    end

    initial begin
        $readmemh("input.hex", input_mem);
        $readmemh("expected.hex", expected_mem);
        pixel_idx = 0;
        out_idx = 0;
        pixel_count = 0;
        mismatch_count = 0;
        first_mismatch = -1;
        source_done = 1'b0;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk);
        start <= 1'b1;
        @(negedge clk);
        start <= 1'b0;
        send_frame();

        repeat (2000000) @(posedge clk);
        if (out_idx != TOTAL)
            $fatal(1, "real golden output count mismatch got=%0d expected=%0d", out_idx, TOTAL);
        if (pixel_count != PIXELS)
            $fatal(1, "real golden pixel count mismatch got=%0d expected=%0d", pixel_count, PIXELS);
        if (mismatch_count != 0)
            $fatal(1, "real golden mismatch count=%0d first=%0d", mismatch_count, first_mismatch);
        $display("CAMUS real 256x256 first-layer golden PASS beats=%0d pixels=%0d", out_idx, pixel_count);
        $finish;
    end
endmodule
