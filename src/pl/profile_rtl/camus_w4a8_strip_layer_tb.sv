`timescale 1ns/1ps

module camus_w4a8_strip_layer_tb;
    localparam integer BEATS = 2048;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic load_start = 1'b0;
    logic compute_start = 1'b0;
    logic compute_bank = 1'b0;
    logic [12:0] load_words;
    logic [19:0] row_stride_words, output_row_base_words;
    logic [8:0] output_height, width;
    logic [3:0] input_groups, output_groups;
    logic kernel_3x3, pad_top, pad_bottom, pad_left, pad_right;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [16:0] pixel_count;
    logic relu_enable;
    logic [2:0] profile_token_events;
    logic output_capacity = 1'b1;
    logic s_axis_tvalid = 1'b0;
    logic s_axis_tready;
    logic [127:0] s_axis_tdata = '0;
    logic [15:0] s_axis_tkeep = 16'hffff;
    logic s_axis_tlast = 1'b0;
    logic output_valid;
    logic [15:0] output_pixel;
    logic [3:0] output_group;
    logic [31:0] output_q8;
    logic busy, done, error;
    logic load_done, load_busy, loaded_bank;
    logic [1:0] bank_ready;
    logic [31:0] cycle_count;

    logic [127:0] axis_beats [0:BEATS-1];
    integer config_file, expected_file;
    integer scan_count, beat, expected_total, output_count, errors;
    reg [31:0] expected_q8;

    always #5 clk = ~clk;

    camus_w4a8_strip_layer dut (.*);

    always @(posedge clk) begin
        if (!rst && output_valid) begin
            scan_count = $fscanf(expected_file, "%h\n", expected_q8);
            if (scan_count != 1) begin
                $display("FAIL unexpected output pixel=%0d group=%0d", output_pixel, output_group);
                errors = errors + 1;
            end else if (output_q8 !== expected_q8) begin
                if (errors < 20)
                    $display("FAIL pixel=%0d group=%0d got=%h expected=%h",
                             output_pixel, output_group, output_q8, expected_q8);
                errors = errors + 1;
            end
            output_count = output_count + 1;
        end
    end

    initial begin
        output_count = 0;
        errors = 0;
        $readmemh("axis_beats.hex", axis_beats);
        config_file = $fopen("config.txt", "r");
        expected_file = $fopen("expected.hex", "r");
        if (config_file == 0 || expected_file == 0) begin
            $display("FAIL vectors unavailable");
            $finish;
        end
        scan_count = $fscanf(
            config_file, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
            load_words, row_stride_words, output_height, width,
            input_groups, output_groups, kernel_3x3, output_row_base_words,
            pad_top, pad_bottom, pad_left, pad_right,
            weight_base, parameter_base, tokens_per_output_group,
            relu_enable, pixel_count
        );
        if (scan_count != 17) begin
            $display("FAIL config fields=%0d", scan_count);
            $finish;
        end
        scan_count = $fscanf(expected_file, "%d\n", expected_total);

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        load_start = 1'b1;
        @(negedge clk);
        load_start = 1'b0;

        for (beat = 0; beat < BEATS; beat = beat + 1) begin
            while (!s_axis_tready) @(negedge clk);
            s_axis_tdata = axis_beats[beat];
            s_axis_tlast = beat == BEATS - 1;
            s_axis_tvalid = 1'b1;
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast = 1'b0;
        end

        wait (load_done);
        @(negedge clk);
        compute_bank = loaded_bank;
        compute_start = 1'b1;
        @(negedge clk);
        compute_start = 1'b0;

        wait (done);
        @(posedge clk);
        @(negedge clk);
        if (output_count != expected_total) begin
            $display("FAIL outputs=%0d expected=%0d", output_count, expected_total);
            errors = errors + 1;
        end
        if (error) begin
            $display("FAIL integrated error flag");
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS camus_w4a8_strip_layer outputs=%0d cycles=%0d",
                     output_count, cycle_count);
        else
            $display("FAIL camus_w4a8_strip_layer errors=%0d", errors);
        $finish;
    end
endmodule
