`timescale 1ns/1ps

// One complete tiled layer datapath. Loading and compute have independent
// controls so one BRAM bank can be filled while the other bank is consumed.
module camus_w4a8_strip_layer #(
    parameter integer CACHE_DEPTH = 4096,
    parameter integer CACHE_ADDR_W = $clog2(CACHE_DEPTH),
    parameter integer SIMD = 8
) (
    input  logic clk,
    input  logic rst,
    input  logic load_start,
    input  logic compute_start,
    input  logic compute_bank,

    input  logic [CACHE_ADDR_W:0] load_words,
    input  logic [19:0] row_stride_words,
    input  logic [8:0] output_height,
    input  logic [8:0] width,
    input  logic [3:0] input_groups,
    input  logic [3:0] output_groups,
    input  logic kernel_3x3,
    input  logic [19:0] output_row_base_words,
    input  logic pad_top,
    input  logic pad_bottom,
    input  logic pad_left,
    input  logic pad_right,
    input  logic [9:0] weight_base,
    input  logic [5:0] parameter_base,
    input  logic [6:0] tokens_per_output_group,
    input  logic [16:0] pixel_count,
    input  logic relu_enable,
    input  logic output_capacity,

    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tlast,

    output logic load_done,
    output logic load_busy,
    output logic loaded_bank,
    output logic [1:0] bank_ready,

    output logic output_valid,
    output logic [15:0] output_pixel,
    output logic [3:0] output_group,
    output logic [31:0] output_q8,
    output logic busy,
    output logic done,
    output logic error,
    output logic [31:0] cycle_count,
    output logic [2:0] profile_token_events
);
    `include "camus_stream_rom_desc.svh"

    typedef enum logic [1:0] {S_IDLE, S_LAUNCH, S_WAIT_BUSY, S_RUN} state_t;
    state_t state;

    logic cache_error;
    logic cache_read_enable, cache_read_valid;
    logic [CACHE_ADDR_W-1:0] cache_read_address;
    logic [SIMD*8-1:0] cache_read_data;
    logic source_start, source_busy, source_done, source_error;
    logic [19:0] source_read_address;
    logic source_activation_valid, source_activation_ready;
    logic [SIMD*8-1:0] source_activation;
    logic scaled_activation_valid, scaled_activation_ready;
    logic [SIMD*8-1:0] scaled_activation;
    logic scaled_last;
    logic engine_start, engine_busy, engine_done, engine_error;
    logic [9:0] rom_weight_address;
    logic [4*SIMD*4-1:0] rom_weight_word;
    logic [5:0] rom_parameter_address;
    logic signed [127:0] rom_bias_word, rom_multiplier_word;
    logic signed [27:0] rom_shift_word;

    logic [19:0] row_stride_reg, output_row_base_reg;
    logic [8:0] output_height_reg, width_reg;
    logic [3:0] input_groups_reg, output_groups_reg;
    logic kernel_reg, pad_top_reg, pad_bottom_reg, pad_left_reg, pad_right_reg;
    logic [9:0] weight_base_reg;
    logic [5:0] parameter_base_reg;
    logic [6:0] tokens_reg;
    logic [16:0] pixels_reg;
    logic relu_reg;
    logic active_read_bank;
    logic signed [31:0] input_multiplier;
    logic signed [6:0] input_shift;

    assign busy = state != S_IDLE;
    assign profile_token_events = {
        engine_busy && scaled_activation_valid && !scaled_activation_ready && !output_capacity,
        scaled_activation_ready && !scaled_activation_valid,
        scaled_activation_valid && scaled_activation_ready
    };
    assign cache_read_address = source_read_address[CACHE_ADDR_W-1:0];

    always_comb begin
        input_multiplier = 32'sd536870912;
        input_shift = 7'sd29;
        case (parameter_base_reg)
            CAMUS_ROM_L00_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L00_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L00_INPUT_SHIFT; end
            CAMUS_ROM_L01_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L01_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L01_INPUT_SHIFT; end
            CAMUS_ROM_L02_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L02_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L02_INPUT_SHIFT; end
            CAMUS_ROM_L03_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L03_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L03_INPUT_SHIFT; end
            CAMUS_ROM_L04_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L04_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L04_INPUT_SHIFT; end
            CAMUS_ROM_L05_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L05_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L05_INPUT_SHIFT; end
            CAMUS_ROM_L06_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L06_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L06_INPUT_SHIFT; end
            CAMUS_ROM_L07_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L07_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L07_INPUT_SHIFT; end
            CAMUS_ROM_L08_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L08_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L08_INPUT_SHIFT; end
            CAMUS_ROM_L09_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L09_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L09_INPUT_SHIFT; end
            CAMUS_ROM_L10_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L10_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L10_INPUT_SHIFT; end
            CAMUS_ROM_L11_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L11_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L11_INPUT_SHIFT; end
            CAMUS_ROM_L12_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L12_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L12_INPUT_SHIFT; end
            CAMUS_ROM_L13_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L13_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L13_INPUT_SHIFT; end
            CAMUS_ROM_L14_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L14_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L14_INPUT_SHIFT; end
            CAMUS_ROM_L15_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L15_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L15_INPUT_SHIFT; end
            CAMUS_ROM_L16_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L16_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L16_INPUT_SHIFT; end
            CAMUS_ROM_L17_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L17_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L17_INPUT_SHIFT; end
            CAMUS_ROM_L18_PARAM_OFFSET: begin input_multiplier=CAMUS_ROM_L18_INPUT_MULTIPLIER; input_shift=CAMUS_ROM_L18_INPUT_SHIFT; end
            default: ;
        endcase
    end

    generate if (SIMD == 16) begin : g_wide_cache
    camus_feature_tile_cache16 #(.DEPTH(CACHE_DEPTH)) u_cache (
        .clk(clk), .rst(rst), .load_start(load_start), .load_words(load_words),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast), .load_done(load_done),
        .load_busy(load_busy), .loaded_bank(loaded_bank),
        .read_enable(cache_read_enable), .read_bank(active_read_bank),
        .read_address(cache_read_address), .read_data(cache_read_data),
        .read_valid(cache_read_valid), .bank_ready(bank_ready),
        .error(cache_error)
    );
    end else begin : g_narrow_cache
    camus_feature_tile_cache #(.DEPTH(CACHE_DEPTH)) u_cache (
        .clk(clk), .rst(rst), .load_start(load_start), .load_words(load_words),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast), .load_done(load_done),
        .load_busy(load_busy), .loaded_bank(loaded_bank),
        .read_enable(cache_read_enable), .read_bank(active_read_bank),
        .read_address(cache_read_address), .read_data(cache_read_data),
        .read_valid(cache_read_valid), .bank_ready(bank_ready),
        .error(cache_error)
    );
    end endgenerate

    camus_window_token_source #(.SIMD(SIMD)) u_source (
        .clk(clk), .rst(rst), .start(source_start),
        .feature_base(20'd0), .row_stride_words(row_stride_reg),
        .height(output_height_reg), .width(width_reg),
        .input_groups(input_groups_reg), .output_groups(output_groups_reg),
        .kernel_3x3(kernel_reg), .output_row_base_words(output_row_base_reg),
        .pad_top(pad_top_reg), .pad_bottom(pad_bottom_reg),
        .pad_left(pad_left_reg), .pad_right(pad_right_reg),
        .feature_read_enable(cache_read_enable),
        .feature_read_address(source_read_address),
        .feature_read_data(cache_read_data),
        .activation_valid(source_activation_valid),
        .activation_u8(source_activation),
        .activation_ready(source_activation_ready),
        .busy(source_busy), .done(source_done), .error(source_error)
    );

    camus_rescale_group_axis #(.LANES(SIMD)) u_input_rescale (
        .clk(clk), .rst(rst),
        .s_valid(source_activation_valid), .s_ready(source_activation_ready),
        .s_data(source_activation), .low_multiplier(input_multiplier),
        .low_shift(input_shift), .high_multiplier(input_multiplier),
        .high_shift(input_shift), .split_lane(($clog2(SIMD)+1)'(SIMD)), .s_last(1'b0),
        .m_valid(scaled_activation_valid), .m_ready(scaled_activation_ready),
        .m_data(scaled_activation), .m_last(scaled_last)
    );

    camus_stream_parameter_rom #(.WEIGHT_WORDS(1024), .SIMD(SIMD)) u_rom (
        .clk(clk), .weight_address(rom_weight_address), .weight_word(rom_weight_word),
        .parameter_address(rom_parameter_address), .bias_word(rom_bias_word),
        .multiplier_word(rom_multiplier_word), .shift_word(rom_shift_word)
    );

    camus_w4a8_layer_engine #(.SIMD(SIMD)) u_engine (
        .clk(clk), .rst(rst), .start(engine_start),
        .weight_base(weight_base_reg), .parameter_base(parameter_base_reg),
        .tokens_per_output_group(tokens_reg), .output_groups(output_groups_reg),
        .pixel_count(pixels_reg), .relu_enable(relu_reg),
        .output_capacity(output_capacity),
        .pair_inputs(input_groups_reg > 1),
        .rom_weight_address(rom_weight_address), .rom_weight_word(rom_weight_word),
        .rom_parameter_address(rom_parameter_address),
        .rom_bias_word(rom_bias_word), .rom_multiplier_word(rom_multiplier_word),
        .rom_shift_word(rom_shift_word),
        .activation_valid(scaled_activation_valid),
        .activation_u8(scaled_activation), .activation_ready(scaled_activation_ready),
        .output_valid(output_valid), .output_pixel(output_pixel),
        .output_group(output_group), .output_q8(output_q8),
        .busy(engine_busy), .done(engine_done), .error(engine_error)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            source_start <= 1'b0;
            engine_start <= 1'b0;
            row_stride_reg <= '0;
            output_row_base_reg <= '0;
            output_height_reg <= '0;
            width_reg <= '0;
            input_groups_reg <= '0;
            output_groups_reg <= '0;
            kernel_reg <= 1'b0;
            pad_top_reg <= 1'b0;
            pad_bottom_reg <= 1'b0;
            pad_left_reg <= 1'b0;
            pad_right_reg <= 1'b0;
            weight_base_reg <= '0;
            parameter_base_reg <= '0;
            tokens_reg <= '0;
            pixels_reg <= '0;
            relu_reg <= 1'b0;
            active_read_bank <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycle_count <= '0;
        end else begin
            source_start <= 1'b0;
            engine_start <= 1'b0;
            done <= 1'b0;

            if (busy)
                cycle_count <= cycle_count + 1'b1;

            if (compute_start && state != S_IDLE)
                error <= 1'b1;

            case (state)
                S_IDLE: if (compute_start) begin
                    if (output_height == 0 || width == 0
                            || input_groups == 0 || output_groups == 0
                            || pixel_count == 0 || !bank_ready[compute_bank]) begin
                        error <= 1'b1;
                    end else begin
                        row_stride_reg <= row_stride_words;
                        output_row_base_reg <= output_row_base_words;
                        output_height_reg <= output_height;
                        width_reg <= width;
                        input_groups_reg <= input_groups;
                        output_groups_reg <= output_groups;
                        kernel_reg <= kernel_3x3;
                        pad_top_reg <= pad_top;
                        pad_bottom_reg <= pad_bottom;
                        pad_left_reg <= pad_left;
                        pad_right_reg <= pad_right;
                        weight_base_reg <= weight_base;
                        parameter_base_reg <= parameter_base;
                        tokens_reg <= (SIMD == 16 && input_groups > 1)
                            ? tokens_per_output_group >> 1 : tokens_per_output_group;
                        pixels_reg <= pixel_count;
                        relu_reg <= relu_enable;
                        active_read_bank <= compute_bank;
                        cycle_count <= 0;
                        error <= 1'b0;
                        state <= S_LAUNCH;
                    end
                end
                S_LAUNCH: begin
                    source_start <= 1'b1;
                    engine_start <= 1'b1;
                    state <= S_WAIT_BUSY;
                end
                S_WAIT_BUSY: if (source_busy && engine_busy)
                    state <= S_RUN;
                S_RUN: if (!source_busy && !engine_busy) begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase

            if (cache_error || source_error || engine_error)
                error <= 1'b1;
        end
    end
endmodule
