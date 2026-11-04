`timescale 1ns/1ps

module camus_w4a8_mvu_tb;
    localparam integer PE = 4;
    localparam integer SIMD = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_ready;
    logic first, last, relu_enable;
    logic [SIMD*8-1:0] activations_u8;
    logic [PE*SIMD*4-1:0] weights_w4;
    logic signed [PE*32-1:0] bias;
    logic signed [PE*32-1:0] requant_mult;
    logic signed [PE*7-1:0] requant_shift;
    logic out_valid;
    logic [PE*8-1:0] outputs_q8;

    integer input_file, expected_file;
    integer scan_count, expected_count, errors, cycles;
    reg [PE*8-1:0] expected_value;

    always #5 clk = ~clk;

    camus_w4a8_mvu #(.PE(PE), .SIMD(SIMD)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .first(first), .last(last), .activations_u8(activations_u8),
        .weights_w4(weights_w4), .bias(bias),
        .requant_mult(requant_mult), .requant_shift(requant_shift),
        .relu_enable(relu_enable), .out_valid(out_valid),
        .outputs_q8(outputs_q8)
    );

    always @(posedge clk) begin
        if (!rst && out_valid) begin
            scan_count = $fscanf(expected_file, "%h\n", expected_value);
            if (scan_count != 1) begin
                $display("FAIL unexpected output %h", outputs_q8);
                errors = errors + 1;
            end else if (outputs_q8 !== expected_value) begin
                $display("FAIL output %0d got=%h expected=%h", expected_count,
                         outputs_q8, expected_value);
                errors = errors + 1;
            end
            expected_count = expected_count + 1;
        end
    end

    initial begin
        errors = 0;
        expected_count = 0;
        cycles = 0;
        first = 0;
        last = 0;
        relu_enable = 0;
        activations_u8 = '0;
        weights_w4 = '0;
        bias = '0;
        requant_mult = '0;
        requant_shift = '0;

        input_file = $fopen("camus_w4a8_mvu_input.txt", "r");
        expected_file = $fopen("camus_w4a8_mvu_expected.txt", "r");
        if (input_file == 0 || expected_file == 0) begin
            $display("FAIL vector files could not be opened");
            $finish;
        end

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        while (!$feof(input_file)) begin
            @(negedge clk);
            scan_count = $fscanf(
                input_file, "%d %d %h %h %h %h %h %d\n",
                first, last, activations_u8, weights_w4, bias,
                requant_mult, requant_shift, relu_enable
            );
            if (scan_count == 8) begin
                in_valid = 1'b1;
                @(posedge clk);
            end
        end
        @(negedge clk);
        in_valid = 1'b0;

        while (expected_count < 8 && cycles < 100) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (expected_count != 8) begin
            $display("FAIL expected 8 outputs, observed %0d", expected_count);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS camus_w4a8_mvu 75 input tokens, 8 output groups");
        else
            $display("FAIL camus_w4a8_mvu errors=%0d", errors);
        $fclose(input_file);
        $fclose(expected_file);
        $finish;
    end
endmodule
