`timescale 1ns/1ps

module camus_w4a8_layer_engine_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [3:0] output_groups;
    logic [16:0] pixel_count;
    logic relu_enable;
    logic output_capacity = 1'b1;
    logic [9:0] rom_weight_address;
    logic [127:0] rom_weight_word;
    logic [5:0] rom_parameter_address;
    logic signed [127:0] rom_bias_word;
    logic signed [127:0] rom_multiplier_word;
    logic signed [27:0] rom_shift_word;
    logic activation_valid = 1'b0;
    logic [63:0] activation_u8;
    logic activation_ready;
    logic output_valid;
    logic [15:0] output_pixel;
    logic [3:0] output_group;
    logic [31:0] output_q8;
    logic busy, done, error;

    integer jobs_file, activations_file, expected_file;
    integer jobs_total, expected_total, job_index;
    integer scan_count, output_count, errors, watchdog;
    integer expected_pixel, expected_group;
    reg [31:0] expected_q8;

    always #5 clk = ~clk;

    camus_stream_parameter_rom #(
        .WEIGHT_WORDS(1000),
        .PARAMETER_GROUPS(60)
    ) u_rom (
        .clk(clk),
        .weight_address(rom_weight_address),
        .weight_word(rom_weight_word),
        .parameter_address(rom_parameter_address),
        .bias_word(rom_bias_word),
        .multiplier_word(rom_multiplier_word),
        .shift_word(rom_shift_word)
    );

    camus_w4a8_layer_engine u_engine (
        .clk(clk), .rst(rst), .start(start),
        .weight_base(weight_base), .parameter_base(parameter_base),
        .tokens_per_output_group(tokens_per_output_group),
        .output_groups(output_groups), .pixel_count(pixel_count),
        .relu_enable(relu_enable), .output_capacity(output_capacity),
        .rom_weight_address(rom_weight_address), .rom_weight_word(rom_weight_word),
        .rom_parameter_address(rom_parameter_address),
        .rom_bias_word(rom_bias_word), .rom_multiplier_word(rom_multiplier_word),
        .rom_shift_word(rom_shift_word),
        .activation_valid(activation_valid), .activation_u8(activation_u8),
        .activation_ready(activation_ready),
        .output_valid(output_valid), .output_pixel(output_pixel),
        .output_group(output_group), .output_q8(output_q8),
        .busy(busy), .done(done), .error(error)
    );

    always @(posedge clk) begin
        if (!rst && output_valid) begin
            scan_count = $fscanf(
                expected_file, "%d %d %h\n",
                expected_pixel, expected_group, expected_q8
            );
            if (scan_count != 3) begin
                $display("FAIL unexpected output pixel=%0d group=%0d data=%h",
                         output_pixel, output_group, output_q8);
                errors = errors + 1;
            end else begin
                if (output_pixel !== expected_pixel[15:0]
                        || output_group !== expected_group[3:0]) begin
                    $display("FAIL tag got=%0d/%0d expected=%0d/%0d",
                             output_pixel, output_group, expected_pixel, expected_group);
                    errors = errors + 1;
                end
                if (output_q8 !== expected_q8) begin
                    $display("FAIL data output=%0d got=%h expected=%h",
                             output_count, output_q8, expected_q8);
                    errors = errors + 1;
                end
            end
            output_count = output_count + 1;
        end
    end

    initial begin
        errors = 0;
        output_count = 0;
        activation_u8 = '0;
        weight_base = '0;
        parameter_base = '0;
        tokens_per_output_group = '0;
        output_groups = '0;
        pixel_count = '0;
        relu_enable = 1'b0;

        jobs_file = $fopen("camus_layer_engine_jobs.txt", "r");
        activations_file = $fopen("camus_layer_engine_activations.txt", "r");
        expected_file = $fopen("camus_layer_engine_expected.txt", "r");
        if (jobs_file == 0 || activations_file == 0 || expected_file == 0) begin
            $display("FAIL layer-engine vector files could not be opened");
            $finish;
        end
        scan_count = $fscanf(jobs_file, "%d\n", jobs_total);
        scan_count = $fscanf(expected_file, "%d\n", expected_total);

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (job_index = 0; job_index < jobs_total; job_index = job_index + 1) begin
            scan_count = $fscanf(
                jobs_file, "%d %d %d %d %d %d\n",
                weight_base, parameter_base, tokens_per_output_group,
                output_groups, relu_enable, pixel_count
            );
            if (scan_count != 6) begin
                $display("FAIL missing job %0d", job_index);
                errors = errors + 1;
                $finish;
            end
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            watchdog = 0;
            while (!done && watchdog < 200000) begin
                if (activation_ready) begin
                    scan_count = $fscanf(activations_file, "%h\n", activation_u8);
                    if (scan_count != 1) begin
                        $display("FAIL activation stream ended in job %0d", job_index);
                        errors = errors + 1;
                        $finish;
                    end
                    activation_valid = 1'b1;
                end else begin
                    activation_valid = 1'b0;
                end
                @(posedge clk);
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            activation_valid = 1'b0;
            if (watchdog >= 200000) begin
                $display("FAIL watchdog in job %0d", job_index);
                errors = errors + 1;
                $finish;
            end
            if (error) begin
                $display("FAIL engine error in job %0d", job_index);
                errors = errors + 1;
                $finish;
            end
            // Let the checker observe the final nonblocking output pulse.
            @(posedge clk);
            @(negedge clk);
        end

        repeat (3) @(posedge clk);
        if (output_count != expected_total) begin
            $display("FAIL expected %0d output groups, observed %0d",
                     expected_total, output_count);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS camus_w4a8_layer_engine jobs=%0d outputs=%0d",
                     jobs_total, output_count);
        else
            $display("FAIL camus_w4a8_layer_engine errors=%0d", errors);
        $finish;
    end
endmodule
