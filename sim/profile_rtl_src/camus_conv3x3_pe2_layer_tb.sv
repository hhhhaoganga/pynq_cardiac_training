`timescale 1ns/1ps
module camus_conv3x3_pe2_layer_tb;
    localparam integer W = 5;
    localparam integer IN_CH = 16;
    localparam integer GROUPS = 8;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic signed [IN_CH*8-1:0] in_pixel = '0;
    logic in_ready, out_valid, out_pixel_last, out_last, busy;
    logic signed [15:0] out_data;
    integer r, c, ch, outputs, pixel_last_count;
    integer accepted;
    logic signed [15:0] first_output;

    camus_conv3x3_pe2_layer #(.LAYER_ID(1), .WIDTH(W), .IN_CH(IN_CH), .OUT_CH(16)) dut (
        .clk, .rst, .in_valid, .in_pixel, .in_ready, .out_valid,
        .out_data, .out_pixel_last, .out_last, .busy);

    always @(posedge clk) begin
        if (out_valid) begin
            if (outputs == 0) begin
                first_output <= out_data;
                $display("first rtl={%0d,%0d} accum={%0d,%0d} mult={%0d,%0d} shift={%0d,%0d}",
                    $signed(out_data[15:8]), $signed(out_data[7:0]),
                    $signed(dut.u_tile.final_accum[1]), $signed(dut.u_tile.final_accum[0]),
                    $signed(dut.u_tile.final_mult[1]), $signed(dut.u_tile.final_mult[0]),
                    $signed(dut.u_tile.final_shift[1]), $signed(dut.u_tile.final_shift[0]));
            end
            outputs <= outputs + 1;
            if (out_pixel_last) begin
                pixel_last_count <= pixel_last_count + 1;
            end
        end
    end

    initial begin
        outputs = 0;
        pixel_last_count = 0;
        accepted = 0;
        first_output = '0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        for (r = 0; r < W; r = r + 1) begin
            for (c = 0; c < W; c = c + 1) begin
                for (ch = 0; ch < IN_CH; ch = ch + 1)
                    in_pixel[ch*8 +: 8] <= $signed((r + 1) * (c + 2) + ch - 8);
                while (!in_ready) @(negedge clk);
                in_valid <= 1'b1;
                @(posedge clk);
                @(negedge clk);
                accepted = accepted + 1;
                in_valid <= 1'b0;
            end
        end
        repeat (5000) @(posedge clk);
        if (outputs != (W-2)*(W-2)*GROUPS)
            $fatal(1, "layer2 output count mismatch got=%0d expected=%0d", outputs, (W-2)*(W-2)*GROUPS);
        if (pixel_last_count != (W-2)*(W-2))
            $fatal(1, "layer2 pixel boundary mismatch got=%0d expected=%0d", pixel_last_count, (W-2)*(W-2));
        if ($signed(first_output[7:0]) !== 10 || $signed(first_output[15:8]) !== 0)
            $fatal(1, "layer2 golden mismatch got={%0d,%0d} expected={0,10}",
                $signed(first_output[15:8]), $signed(first_output[7:0]));
        $display("CAMUS shared PE2 layer2 scheduler smoke PASS groups=%0d pixels=%0d", outputs, pixel_last_count);
        $finish;
    end
endmodule
