`timescale 1ns/1ps
module camus_enc12_chain_tb;
    localparam integer W0 = 5;
    localparam integer PE = 2;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;
    logic in_valid = 0;
    logic signed [23:0] in_pixel;
    logic in_ready, l0_valid, l0_last, l0_busy;
    logic signed [15:0] l0_data;
    logic packed_valid, packed_data_ready, fifo_valid, fifo_ready, fifo_overflow;
    logic signed [127:0] packed_data, fifo_data;
    logic l2_valid, l2_pixel_last, l2_last, l2_busy;
    logic signed [15:0] l2_data;
    integer r, c, ch, outputs;

    camus_conv3x3_pe2_layer #(.LAYER_ID(0), .WIDTH(W0), .IN_CH(3), .OUT_CH(16)) l0 (
        .clk, .rst, .in_valid, .in_pixel, .in_ready, .out_valid(l0_valid),
        .out_data(l0_data), .out_pixel_last(l0_last), .out_last(), .busy(l0_busy));
    camus_feature_repacker repack (
        .clk, .rst, .in_valid(l0_valid), .in_data(l0_data),
        .in_pixel_last(l0_last), .out_valid(packed_valid), .out_data(packed_data), .busy());
    camus_feature_fifo #(.WIDTH(128), .DEPTH(16)) fifo (
        .clk, .rst, .in_valid(packed_valid), .in_ready(packed_data_ready),
        .in_data(packed_data), .out_valid(fifo_valid), .out_ready(fifo_ready),
        .out_data(fifo_data), .overflow(fifo_overflow));
    camus_conv3x3_pe2_layer #(.LAYER_ID(1), .WIDTH(3), .IN_CH(16), .OUT_CH(16)) l2 (
        .clk, .rst, .in_valid(fifo_valid && fifo_ready), .in_pixel(fifo_data),
        .in_ready(fifo_ready), .out_valid(l2_valid), .out_data(l2_data),
        .out_pixel_last(l2_pixel_last), .out_last(l2_last), .busy(l2_busy));

    always @(posedge clk) if (l2_valid) outputs <= outputs + 1;

    initial begin
        outputs = 0;
        in_pixel = '0;
        repeat (3) @(posedge clk);
        rst <= 0;
        for (r = 0; r < W0; r = r + 1) begin
            for (c = 0; c < W0; c = c + 1) begin
                for (ch = 0; ch < 3; ch = ch + 1)
                    in_pixel[ch*8 +: 8] <= $signed((r+1)*(c+2)+ch-4);
                while (!in_ready) @(negedge clk);
                in_valid <= 1;
                @(posedge clk);
                @(negedge clk);
                in_valid <= 0;
            end
        end
        repeat (12000) @(posedge clk);
        if (fifo_overflow) $fatal(1, "layer FIFO overflowed");
        if (outputs != 8) $fatal(1, "encoder chain output mismatch got=%0d expected=8", outputs);
        $display("CAMUS real enc1->enc1 layer2 chain PASS outputs=%0d", outputs);
        $finish;
    end
endmodule
