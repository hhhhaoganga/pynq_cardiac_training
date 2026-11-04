`timescale 1ns/1ps

// One PE4xSIMD8 convolution layer datapath. The window/tile scheduler supplies
// SIMD8 activation tokens in ky/kx/input-group order and repeats the same
// token sequence for each output group. Weight and parameter reads are
// prefetched so adjacent output groups have no control bubble.
module camus_w4a8_layer_engine #(
    parameter integer WEIGHT_ADDR_W = 10,
    parameter integer PARAM_ADDR_W = 6,
    parameter integer TAG_FIFO_DEPTH = 16,
    parameter integer SIMD = 8
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [WEIGHT_ADDR_W-1:0] weight_base,
    input  logic [PARAM_ADDR_W-1:0] parameter_base,
    input  logic [6:0] tokens_per_output_group,
    input  logic [3:0] output_groups,
    input  logic [16:0] pixel_count,
    input  logic relu_enable,
    input  logic output_capacity,
    input  logic pair_inputs,

    output logic [WEIGHT_ADDR_W-1:0] rom_weight_address,
    input  logic [4*SIMD*4-1:0] rom_weight_word,
    output logic [PARAM_ADDR_W-1:0] rom_parameter_address,
    input  logic signed [127:0] rom_bias_word,
    input  logic signed [127:0] rom_multiplier_word,
    input  logic signed [27:0] rom_shift_word,

    input  logic activation_valid,
    input  logic [SIMD*8-1:0] activation_u8,
    output logic activation_ready,

    output logic output_valid,
    output logic [15:0] output_pixel,
    output logic [3:0] output_group,
    output logic [31:0] output_q8,
    output logic busy,
    output logic done,
    output logic error
);
    localparam integer FIFO_PTR_W = $clog2(TAG_FIFO_DEPTH);

    typedef enum logic [1:0] {S_IDLE, S_PREFETCH, S_RUN, S_DRAIN} state_t;
    state_t state;

    logic [WEIGHT_ADDR_W-1:0] weight_base_reg;
    logic [PARAM_ADDR_W-1:0] parameter_base_reg;
    logic [6:0] tokens_reg;
    logic [3:0] groups_reg;
    logic [16:0] pixels_reg;
    logic relu_reg;

    logic [WEIGHT_ADDR_W-1:0] weight_cursor;
    logic [6:0] token_index;
    logic [3:0] group_index;
    logic [15:0] pixel_index;

    logic signed [127:0] current_bias;
    logic signed [127:0] current_multiplier;
    logic signed [27:0] current_shift;

    logic fire;
    logic token_last;
    logic group_last;
    logic pixel_last;
    logic [3:0] immediate_group;
    logic [3:0] following_group;

    logic mvu_valid;
    logic mvu_ready;
    logic mvu_out_valid;
    logic [31:0] mvu_output;
    logic pipe_valid;
    logic pipe_first, pipe_last, pipe_relu;
    logic [SIMD*8-1:0] pipe_activation;
    logic [4*SIMD*4-1:0] pipe_weight;
    logic pair_reg;
    logic [1:0] weight_step;
    logic [4*SIMD*4-1:0] effective_weight;
    assign weight_step = (SIMD == 16 && pair_reg) ? 2'd2 : 2'd1;
    generate for (genvar p = 0; p < 4; p = p + 1) begin : g_weight
        assign effective_weight[p*SIMD*4 +: 32] = rom_weight_word[p*SIMD*4 +: 32];
        if (SIMD == 16) begin : g_upper
            assign effective_weight[p*64+32 +: 32] = pair_reg
                ? rom_weight_word[p*64+32 +: 32] : 32'd0;
        end
    end endgenerate
    logic signed [127:0] pipe_bias, pipe_multiplier;
    logic signed [27:0] pipe_shift;

    logic [15:0] tag_pixel [0:TAG_FIFO_DEPTH-1];
    logic [3:0] tag_group [0:TAG_FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0] tag_head, tag_tail;
    logic [FIFO_PTR_W:0] tag_count;
    logic tag_push, tag_pop;

    integer i;

    assign busy = state != S_IDLE;
    assign activation_ready = (state == S_RUN) && mvu_ready && output_capacity;
    assign fire = activation_valid && activation_ready;
    assign token_last = token_index == tokens_reg - 1'b1;
    assign group_last = group_index == groups_reg - 1'b1;
    assign pixel_last = pixel_index == pixels_reg - 1'b1;
    assign mvu_valid = pipe_valid;
    assign tag_push = fire && token_last;
    assign tag_pop = mvu_out_valid;

    always_comb begin
        immediate_group = group_last ? 4'd0 : group_index + 1'b1;
        following_group = (immediate_group == groups_reg - 1'b1)
            ? 4'd0 : immediate_group + 1'b1;

        rom_weight_address = weight_cursor;
        if (state == S_IDLE && start)
            rom_weight_address = weight_base;
        else if (state == S_PREFETCH)
            rom_weight_address = weight_base_reg;
        else if (state == S_RUN && fire) begin
            if (token_last && group_last)
                rom_weight_address = weight_base_reg;
            else
                rom_weight_address = weight_cursor + weight_step;
        end

        rom_parameter_address = parameter_base_reg;
        if (state == S_IDLE && start)
            rom_parameter_address = parameter_base;
        else if (state == S_PREFETCH)
            rom_parameter_address = parameter_base_reg
                + ((groups_reg > 1) ? 1'b1 : 1'b0);
        else if (state == S_RUN) begin
            rom_parameter_address = parameter_base_reg
                + ((fire && token_last) ? following_group : immediate_group);
        end
    end

    camus_w4a8_mvu #(.PE(4), .SIMD(SIMD)) u_mvu (
        .clk(clk),
        .rst(rst),
        .in_valid(mvu_valid),
        .in_ready(mvu_ready),
        .first(pipe_first),
        .last(pipe_last),
        .activations_u8(pipe_activation),
        .weights_w4(pipe_weight),
        .bias(pipe_bias),
        .requant_mult(pipe_multiplier),
        .requant_shift(pipe_shift),
        .relu_enable(pipe_relu),
        .out_valid(mvu_out_valid),
        .outputs_q8(mvu_output)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            weight_base_reg <= '0;
            parameter_base_reg <= '0;
            tokens_reg <= '0;
            groups_reg <= '0;
            pixels_reg <= '0;
            relu_reg <= 1'b0;
            pair_reg <= 1'b0;
            weight_cursor <= '0;
            token_index <= '0;
            group_index <= '0;
            pixel_index <= '0;
            current_bias <= '0;
            current_multiplier <= '0;
            current_shift <= '0;
            pipe_valid <= 1'b0;
            pipe_first <= 1'b0;
            pipe_last <= 1'b0;
            pipe_relu <= 1'b0;
            pipe_activation <= '0;
            pipe_weight <= '0;
            pipe_bias <= '0;
            pipe_multiplier <= '0;
            pipe_shift <= '0;
            tag_head <= '0;
            tag_tail <= '0;
            tag_count <= '0;
            output_valid <= 1'b0;
            output_pixel <= '0;
            output_group <= '0;
            output_q8 <= '0;
            done <= 1'b0;
            error <= 1'b0;
            for (i = 0; i < TAG_FIFO_DEPTH; i = i + 1) begin
                tag_pixel[i] <= '0;
                tag_group[i] <= '0;
            end
        end else begin
            output_valid <= 1'b0;
            done <= 1'b0;
            pipe_valid <= fire;

            if (fire) begin
                pipe_first <= token_index == 0;
                pipe_last <= token_last;
                pipe_relu <= relu_reg;
                pipe_activation <= activation_u8;
                pipe_weight <= effective_weight;
                pipe_bias <= current_bias;
                pipe_multiplier <= current_multiplier;
                pipe_shift <= current_shift;
            end

            if (start && state != S_IDLE)
                error <= 1'b1;

            if (state == S_IDLE && start) begin
                if (tokens_per_output_group == 0 || output_groups == 0 || pixel_count == 0) begin
                    error <= 1'b1;
                end else begin
                    weight_base_reg <= weight_base;
                    parameter_base_reg <= parameter_base;
                    tokens_reg <= tokens_per_output_group;
                    groups_reg <= output_groups;
                    pixels_reg <= pixel_count;
                    relu_reg <= relu_enable;
                    pair_reg <= (SIMD == 16) && pair_inputs;
                    weight_cursor <= weight_base;
                    token_index <= 0;
                    group_index <= 0;
                    pixel_index <= 0;
                    tag_head <= 0;
                    tag_tail <= 0;
                    tag_count <= 0;
                    error <= 1'b0;
                    state <= S_PREFETCH;
                end
            end else if (state == S_PREFETCH) begin
                current_bias <= rom_bias_word;
                current_multiplier <= rom_multiplier_word;
                current_shift <= rom_shift_word;
                state <= S_RUN;
            end else if (state == S_RUN && fire) begin
                if (token_last) begin
                    token_index <= 0;
                    current_bias <= rom_bias_word;
                    current_multiplier <= rom_multiplier_word;
                    current_shift <= rom_shift_word;
                    if (group_last) begin
                        group_index <= 0;
                        weight_cursor <= weight_base_reg;
                        if (pixel_last) begin
                            state <= S_DRAIN;
                        end else begin
                            pixel_index <= pixel_index + 1'b1;
                        end
                    end else begin
                        group_index <= group_index + 1'b1;
                        weight_cursor <= weight_cursor + weight_step;
                    end
                end else begin
                    token_index <= token_index + 1'b1;
                    weight_cursor <= weight_cursor + weight_step;
                end
            end

            if (tag_push) begin
                if (tag_count == TAG_FIFO_DEPTH) begin
                    error <= 1'b1;
                end else begin
                    tag_pixel[tag_tail] <= pixel_index;
                    tag_group[tag_tail] <= group_index;
                    tag_tail <= tag_tail + 1'b1;
                end
            end

            if (tag_pop) begin
                if (tag_count == 0) begin
                    error <= 1'b1;
                end else begin
                    output_valid <= 1'b1;
                    output_pixel <= tag_pixel[tag_head];
                    output_group <= tag_group[tag_head];
                    output_q8 <= mvu_output;
                    tag_head <= tag_head + 1'b1;
                    if (state == S_DRAIN
                            && tag_pixel[tag_head] == pixels_reg - 1'b1
                            && tag_group[tag_head] == groups_reg - 1'b1) begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end
                end
            end

            case ({tag_push && tag_count != TAG_FIFO_DEPTH, tag_pop && tag_count != 0})
                2'b10: tag_count <= tag_count + 1'b1;
                2'b01: tag_count <= tag_count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
