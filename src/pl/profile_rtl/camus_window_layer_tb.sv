`timescale 1ns/1ps

module camus_window_layer_tb;
    localparam integer MEMORY_WORDS = 200000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic source_start = 1'b0;
    logic engine_start = 1'b0;
    logic [19:0] feature_base;
    logic [19:0] row_stride_words;
    logic [8:0] height, width;
    logic [3:0] input_groups, output_groups;
    logic kernel_3x3;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [16:0] pixel_count;
    logic relu_enable;
    logic output_capacity = 1'b1;

    logic feature_read_enable;
    logic [19:0] feature_read_address;
    logic [63:0] feature_read_data;
    logic activation_valid, activation_ready;
    logic [63:0] activation_u8;
    logic source_busy, source_done, source_error;
    logic [9:0] rom_weight_address;
    logic [127:0] rom_weight_word;
    logic [5:0] rom_parameter_address;
    logic signed [127:0] rom_bias_word, rom_multiplier_word;
    logic signed [27:0] rom_shift_word;
    logic output_valid;
    logic [15:0] output_pixel;
    logic [3:0] output_group;
    logic [31:0] output_q8;
    logic engine_busy, engine_done, engine_error;

    logic [63:0] feature_memory [0:MEMORY_WORDS-1];
    integer jobs_file, expected_file;
    integer jobs_total, expected_total;
    integer job_index, expected_count, job_expected, job_observed;
    integer scan_count, watchdog, errors;
    reg [31:0] expected_q8;

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (feature_read_enable)
            feature_read_data <= feature_memory[feature_read_address];
    end

    camus_window_token_source u_source (
        .clk(clk), .rst(rst), .start(source_start),
        .feature_base(feature_base), .row_stride_words(row_stride_words),
        .height(height), .width(width), .input_groups(input_groups),
        .output_groups(output_groups), .kernel_3x3(kernel_3x3),
        .output_row_base_words(20'd0),
        .pad_top(1'b1), .pad_bottom(1'b1),
        .pad_left(1'b1), .pad_right(1'b1),
        .feature_read_enable(feature_read_enable),
        .feature_read_address(feature_read_address),
        .feature_read_data(feature_read_data),
        .activation_valid(activation_valid), .activation_u8(activation_u8),
        .activation_ready(activation_ready),
        .busy(source_busy), .done(source_done), .error(source_error)
    );

    camus_stream_parameter_rom #(.WEIGHT_WORDS(1024)) u_rom (
        .clk(clk),
        .weight_address(rom_weight_address), .weight_word(rom_weight_word),
        .parameter_address(rom_parameter_address),
        .bias_word(rom_bias_word), .multiplier_word(rom_multiplier_word),
        .shift_word(rom_shift_word)
    );

    camus_w4a8_layer_engine u_engine (
        .clk(clk), .rst(rst), .start(engine_start),
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
        .busy(engine_busy), .done(engine_done), .error(engine_error)
    );

    always @(posedge clk) begin
        if (!rst && output_valid) begin
            scan_count = $fscanf(expected_file, "%h\n", expected_q8);
            if (scan_count != 1) begin
                $display("FAIL unexpected output job=%0d pixel=%0d group=%0d",
                         job_index, output_pixel, output_group);
                errors = errors + 1;
            end else if (output_q8 !== expected_q8) begin
                if (errors < 20)
                    $display("FAIL job=%0d pixel=%0d group=%0d got=%h expected=%h",
                             job_index, output_pixel, output_group, output_q8, expected_q8);
                errors = errors + 1;
            end
            expected_count = expected_count + 1;
            job_observed = job_observed + 1;
        end
    end

    initial begin
        errors = 0;
        expected_count = 0;
        $readmemh("feature_memory.hex", feature_memory);
        jobs_file = $fopen("jobs.txt", "r");
        expected_file = $fopen("expected.txt", "r");
        if (jobs_file == 0 || expected_file == 0) begin
            $display("FAIL vector files could not be opened");
            $finish;
        end
        scan_count = $fscanf(jobs_file, "%d\n", jobs_total);
        scan_count = $fscanf(expected_file, "%d\n", expected_total);

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (job_index = 0; job_index < jobs_total; job_index = job_index + 1) begin
            scan_count = $fscanf(
                jobs_file, "%d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                feature_base, row_stride_words, height, width, input_groups,
                output_groups, kernel_3x3, weight_base, parameter_base,
                tokens_per_output_group, relu_enable, pixel_count, job_expected
            );
            if (scan_count != 13) begin
                $display("FAIL missing job %0d", job_index);
                $finish;
            end
            job_observed = 0;
            @(negedge clk);
            source_start = 1'b1;
            engine_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            source_start = 1'b0;
            engine_start = 1'b0;

            watchdog = 0;
            while ((source_busy || engine_busy) && watchdog < 5000000) begin
                @(posedge clk);
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            // The final output_valid/busy updates are nonblocking assignments.
            // Give the scoreboard one more active edge to consume that pulse.
            @(posedge clk);
            @(negedge clk);
            if (watchdog >= 5000000) begin
                $display("FAIL watchdog job=%0d source_busy=%0d engine_busy=%0d",
                         job_index, source_busy, engine_busy);
                $finish;
            end
            if (source_error || engine_error) begin
                $display("FAIL error flag job=%0d source=%0d engine=%0d",
                         job_index, source_error, engine_error);
                errors = errors + 1;
            end
            if (job_observed != job_expected) begin
                $display("FAIL output count job=%0d got=%0d expected=%0d",
                         job_index, job_observed, job_expected);
                errors = errors + 1;
            end
            $display("JOB PASS job=%0d cycles=%0d outputs=%0d",
                     job_index, watchdog, job_observed);
            repeat (3) @(posedge clk);
        end

        if (expected_count != expected_total) begin
            $display("FAIL total outputs got=%0d expected=%0d", expected_count, expected_total);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS camus_window_layer full_layers=%0d outputs=%0d",
                     jobs_total, expected_count);
        else
            $display("FAIL camus_window_layer errors=%0d", errors);
        $finish;
    end
endmodule
