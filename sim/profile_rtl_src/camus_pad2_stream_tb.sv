`timescale 1ns/1ps
module camus_pad2_stream_tb;
    localparam integer W = 3;
    localparam integer H = 2;
    localparam integer GROUPS = 8;
    localparam integer TOTAL = W*H*GROUPS;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic start = 1'b0;

    logic in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, out_valid, out_pixel_last, out_last, busy, done;
    logic signed [15:0] out_data;

    logic direct_valid = 1'b0;
    logic direct_ready;
    logic signed [23:0] direct_pixel = '0;
    logic direct_valid_out, direct_pixel_last, direct_last, direct_busy;
    logic signed [15:0] direct_data;

    integer dut_count, direct_count, dut_pixels, direct_pixels;
    integer dut_frames, direct_frames;
    integer i;
    logic signed [15:0] dut_buf [0:TOTAL-1];
    logic signed [15:0] direct_buf [0:TOTAL-1];

    camus_pad2_stream #(.WIDTH(W), .HEIGHT(H), .IN_CH(3), .OUT_CH(16)) dut (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready,
        .out_valid, .out_data, .out_pixel_last, .out_last, .busy, .done);

    camus_conv3x3_pe2_layer #(.LAYER_ID(0), .WIDTH(W+2), .IN_CH(3), .OUT_CH(16)) direct (
        .clk, .rst, .in_valid(direct_valid), .in_pixel(direct_pixel),
        .in_ready(direct_ready), .out_valid(direct_valid_out),
        .out_data(direct_data), .out_pixel_last(direct_pixel_last),
        .out_last(direct_last), .busy(direct_busy));

    task automatic send_source_frame;
        integer r, c, ch;
        begin
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    @(negedge clk);
                    for (ch = 0; ch < 3; ch = ch + 1)
                        in_pixel[ch*8 +: 8] = $signed((r + 1) * (c + 2) + ch - 8);
                    in_valid = 1'b1;
                    while (1) begin
                        @(posedge clk);
                        if (in_ready)
                            break;
                    end
                    @(negedge clk);
                    in_valid = 1'b0;
                end
            end
        end
    endtask

    task automatic send_padded_frame;
        integer y, x, ch;
        begin
            for (y = 0; y < H+2; y = y + 1) begin
                for (x = 0; x < W+2; x = x + 1) begin
                    @(negedge clk);
                    if (x == 0 || x == W+1 || y == 0 || y == H+1)
                        direct_pixel = '0;
                    else begin
                        for (ch = 0; ch < 3; ch = ch + 1)
                            direct_pixel[ch*8 +: 8] = $signed(y * (x + 1) + ch - 8);
                    end
                    direct_valid = 1'b1;
                    while (1) begin
                        @(posedge clk);
                        if (direct_ready)
                            break;
                    end
                    @(negedge clk);
                    direct_valid = 1'b0;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (out_valid) begin
            if (dut_count < TOTAL)
                dut_buf[dut_count] = out_data;
            dut_count = dut_count + 1;
            if (out_pixel_last)
                dut_pixels = dut_pixels + 1;
            if (out_last)
                dut_frames = dut_frames + 1;
        end
        if (direct_valid_out) begin
            if (direct_count < TOTAL)
                direct_buf[direct_count] = direct_data;
            direct_count = direct_count + 1;
            if (direct_pixel_last)
                direct_pixels = direct_pixels + 1;
            if (direct_last)
                direct_frames = direct_frames + 1;
        end
    end

    initial begin
        dut_count = 0;
        direct_count = 0;
        dut_pixels = 0;
        direct_pixels = 0;
        dut_frames = 0;
        direct_frames = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk);
        start <= 1'b1;
        @(negedge clk);
        start <= 1'b0;

        fork
            send_source_frame();
            send_padded_frame();
        join

        repeat (30000) @(posedge clk);
        if (dut_count != TOTAL)
            $fatal(1, "adapter output count mismatch got=%0d expected=%0d", dut_count, TOTAL);
        if (direct_count != TOTAL)
            $fatal(1, "reference output count mismatch got=%0d expected=%0d", direct_count, TOTAL);
        if (dut_pixels != W*H || direct_pixels != W*H)
            $fatal(1, "pixel boundary mismatch adapter=%0d reference=%0d expected=%0d",
                   dut_pixels, direct_pixels, W*H);
        for (i = 0; i < TOTAL; i = i + 1)
            if (dut_buf[i] !== direct_buf[i])
                $fatal(1, "adapter/reference mismatch beat=%0d adapter=%0d reference=%0d",
                       i, $signed(dut_buf[i]), $signed(direct_buf[i]));
        $display("CAMUS same-padding PE2 smoke PASS outputs=%0d pixels=%0d", dut_count, dut_pixels);
        $finish;
    end
endmodule
