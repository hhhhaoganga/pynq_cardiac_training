`timescale 1ns/1ps

// Executes a full convolution layer as horizontal strips. The input loader
// and compute/output engines are independent: while bank N is computed and
// written through S2MM, MM2S fills bank N^1 for the next strip.
module camus_datamover_strip_executor #(
    parameter integer CACHE_DEPTH = 4096,
    parameter integer OUTPUT_FIFO_DEPTH = 32,
    parameter integer SIMD = 8
) (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base_bytes, input logic [31:0] output_base_bytes,
    input logic [19:0] input_row_words,
    input logic [31:0] input_row_bytes, input logic [31:0] input_tile_stride_bytes,
    input logic [31:0] output_row_bytes,
    input logic [8:0] frame_height, input logic [8:0] width,
    input logic [8:0] tile_rows,
    input logic [3:0] input_groups, input logic [3:0] output_groups,
    input logic kernel_3x3,
    input logic [9:0] weight_base, input logic [5:0] parameter_base,
    input logic [6:0] tokens_per_output_group, input logic relu_enable,
    input logic [31:0] watchdog_limit,

    output logic m_axis_mm2s_cmd_tvalid,
    input logic m_axis_mm2s_cmd_tready,
    output logic [71:0] m_axis_mm2s_cmd_tdata,
    input logic s_axis_mm2s_sts_tvalid,
    output logic s_axis_mm2s_sts_tready,
    input logic [7:0] s_axis_mm2s_sts_tdata,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tlast,

    output logic m_axis_s2mm_cmd_tvalid,
    input logic m_axis_s2mm_cmd_tready,
    output logic [71:0] m_axis_s2mm_cmd_tdata,
    input logic s_axis_s2mm_sts_tvalid,
    output logic s_axis_s2mm_sts_tready,
    input logic [7:0] s_axis_s2mm_sts_tdata,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tlast,

    output logic busy, output logic done, output logic error,
    output logic [31:0] cycle_count,
    output logic [31:0] load_wait_cycles,
    output logic [31:0] compute_cycles,
    output logic [31:0] output_wait_cycles,
    output logic [31:0] output_stall_count,
    output logic [15:0] strips_completed,
    output logic [2:0] profile_token_events
);
    typedef enum logic [1:0] {L_IDLE, L_ISSUE, L_RUN} load_state_t;
    typedef enum logic [1:0] {C_IDLE, C_ISSUE, C_RUN} compute_state_t;
    load_state_t load_state;
    compute_state_t compute_state;

    logic running;
    logic descriptor_start, descriptor_valid, descriptor_ready;
    logic [71:0] descriptor_mm2s_command;
    logic [12:0] descriptor_source_words;
    logic [8:0] descriptor_output_y, descriptor_output_rows;
    logic [19:0] descriptor_output_row_base_words;
    logic descriptor_pad_top, descriptor_pad_bottom, descriptor_last;
    logic [3:0] descriptor_tag;
    logic descriptor_busy, descriptor_done, descriptor_error;
    logic descriptor_fire, all_descriptors_issued;

    logic [31:0] input_base_reg, output_base_reg;
    logic [19:0] input_row_words_reg;
    logic [31:0] input_row_bytes_reg, input_tile_stride_bytes_reg;
    logic [31:0] output_row_bytes_reg;
    logic [8:0] frame_height_reg, width_reg, tile_rows_reg;
    logic [3:0] input_groups_reg, output_groups_reg;
    logic kernel_reg, relu_reg;
    logic [9:0] weight_base_reg;
    logic [5:0] parameter_base_reg;
    logic [6:0] tokens_reg;

    logic next_load_bank, next_compute_bank, current_compute_bank;
    logic [1:0] slot_valid;
    logic [8:0] slot_output_rows [0:1];
    logic [19:0] slot_output_row_base_words [0:1];
    logic slot_pad_top [0:1], slot_pad_bottom [0:1], slot_last [0:1];
    logic [3:0] slot_tag [0:1];
    logic [16:0] slot_pixel_count [0:1];
    logic [19:0] slot_total_groups [0:1];
    logic [31:0] slot_output_address [0:1], slot_output_bytes [0:1];

    logic [71:0] load_command_reg;
    logic [12:0] load_words_reg;
    logic [8:0] load_output_rows_reg;
    logic [19:0] load_output_row_base_words_reg;
    logic load_pad_top_reg, load_pad_bottom_reg, load_last_reg;
    logic [3:0] load_tag_reg;
    logic [16:0] load_pixel_count_reg;
    logic [19:0] load_total_groups_reg;
    logic [31:0] load_output_address_reg, load_output_bytes_reg;
    logic load_done_seen, mm2s_status_seen;
    logic mm2s_command_fire, mm2s_status_fire;

    logic strip_load_start, strip_load_done, strip_load_busy, strip_loaded_bank;
    logic [1:0] strip_bank_ready;
    logic strip_compute_start, strip_busy, strip_done, strip_error;
    logic strip_output_valid, strip_output_capacity;
    logic [15:0] strip_output_pixel;
    logic [3:0] strip_output_group;
    logic [31:0] strip_output_q8, strip_cycle_count;

    logic packer_start, packer_busy, packer_done, packer_error;
    logic [19:0] packer_groups_received, packer_groups_written;
    logic [71:0] s2mm_command_reg;
    logic s2mm_status_seen, strip_done_seen, packer_done_seen;
    logic s2mm_command_fire, s2mm_status_fire;
    logic current_last;
    logic [3:0] current_tag;

    logic [17:0] descriptor_pixels_wide;
    logic [35:0] descriptor_bytes_wide;
    logic [21:0] descriptor_groups_wide;
    logic target_load_bank_free, load_complete_now, compute_complete_now;

    assign busy = running;
    assign target_load_bank_free = !slot_valid[next_load_bank]
        && !(compute_state != C_IDLE && current_compute_bank == next_load_bank);
    assign descriptor_ready = running && load_state == L_IDLE
        && !all_descriptors_issued && target_load_bank_free;
    assign descriptor_fire = descriptor_valid && descriptor_ready;

    assign m_axis_mm2s_cmd_tvalid = load_state == L_ISSUE;
    assign m_axis_mm2s_cmd_tdata = load_command_reg;
    assign mm2s_command_fire = m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready;
    assign s_axis_mm2s_sts_tready = load_state == L_RUN && !mm2s_status_seen;
    assign mm2s_status_fire = s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready;
    assign load_complete_now = (load_done_seen || strip_load_done)
        && (mm2s_status_seen || mm2s_status_fire);

    assign m_axis_s2mm_cmd_tvalid = compute_state == C_ISSUE;
    assign m_axis_s2mm_cmd_tdata = s2mm_command_reg;
    assign s2mm_command_fire = m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready;
    assign s_axis_s2mm_sts_tready = compute_state == C_RUN && !s2mm_status_seen;
    assign s2mm_status_fire = s_axis_s2mm_sts_tvalid && s_axis_s2mm_sts_tready;
    assign compute_complete_now = (strip_done_seen || strip_done)
        && (packer_done_seen || packer_done)
        && (s2mm_status_seen || s2mm_status_fire);

    assign descriptor_pixels_wide = descriptor_output_rows * width_reg;
    assign descriptor_bytes_wide = descriptor_output_rows * output_row_bytes_reg;
    assign descriptor_groups_wide = descriptor_pixels_wide * output_groups_reg;

    camus_strip_descriptor u_descriptor (
        .clk(clk), .rst(rst), .start(descriptor_start),
        .feature_base_bytes(input_base_reg), .row_words(input_row_words_reg),
        .row_bytes(input_row_bytes_reg), .tile_stride_bytes(input_tile_stride_bytes_reg),
        .frame_height(frame_height_reg), .tile_rows(tile_rows_reg), .kernel_3x3(kernel_reg),
        .descriptor_valid(descriptor_valid), .descriptor_ready(descriptor_ready),
        .mm2s_command(descriptor_mm2s_command),
        .source_words(descriptor_source_words), .output_y(descriptor_output_y),
        .output_rows(descriptor_output_rows),
        .output_row_base_words(descriptor_output_row_base_words),
        .pad_top(descriptor_pad_top), .pad_bottom(descriptor_pad_bottom),
        .last_tile(descriptor_last), .tile_tag(descriptor_tag),
        .busy(descriptor_busy), .done(descriptor_done), .error(descriptor_error)
    );

    camus_w4a8_strip_layer #(.CACHE_DEPTH(CACHE_DEPTH), .SIMD(SIMD)) u_strip (
        .clk(clk), .rst(rst),
        .load_start(strip_load_start), .compute_start(strip_compute_start),
        .compute_bank(current_compute_bank), .load_words(load_words_reg),
        .row_stride_words(input_row_words_reg),
        .output_height(slot_output_rows[current_compute_bank]), .width(width_reg),
        .input_groups(input_groups_reg), .output_groups(output_groups_reg),
        .kernel_3x3(kernel_reg),
        .output_row_base_words(slot_output_row_base_words[current_compute_bank]),
        .pad_top(slot_pad_top[current_compute_bank]),
        .pad_bottom(slot_pad_bottom[current_compute_bank]),
        .pad_left(kernel_reg), .pad_right(kernel_reg),
        .weight_base(weight_base_reg), .parameter_base(parameter_base_reg),
        .tokens_per_output_group(tokens_reg),
        .pixel_count(slot_pixel_count[current_compute_bank]),
        .relu_enable(relu_reg), .output_capacity(strip_output_capacity),
        .s_axis_tvalid(s_axis_mm2s_tvalid), .s_axis_tready(s_axis_mm2s_tready),
        .s_axis_tdata(s_axis_mm2s_tdata), .s_axis_tkeep(s_axis_mm2s_tkeep),
        .s_axis_tlast(s_axis_mm2s_tlast),
        .load_done(strip_load_done), .load_busy(strip_load_busy),
        .loaded_bank(strip_loaded_bank), .bank_ready(strip_bank_ready),
        .output_valid(strip_output_valid), .output_pixel(strip_output_pixel),
        .output_group(strip_output_group), .output_q8(strip_output_q8),
        .busy(strip_busy), .done(strip_done), .error(strip_error),
        .cycle_count(strip_cycle_count), .profile_token_events(profile_token_events)
    );

    camus_output_axis_packer #(
        .FIFO_DEPTH(OUTPUT_FIFO_DEPTH), .PIPELINE_RESERVE(12)
    ) u_packer (
        .clk(clk), .rst(rst), .start(packer_start),
        .total_groups(slot_total_groups[current_compute_bank]),
        .groups_per_pixel(output_groups_reg),
        .in_valid(strip_output_valid), .in_q8(strip_output_q8),
        .output_capacity(strip_output_capacity),
        .m_axis_tvalid(m_axis_s2mm_tvalid), .m_axis_tready(m_axis_s2mm_tready),
        .m_axis_tdata(m_axis_s2mm_tdata), .m_axis_tkeep(m_axis_s2mm_tkeep),
        .m_axis_tlast(m_axis_s2mm_tlast), .busy(packer_busy), .done(packer_done),
        .error(packer_error), .groups_received(packer_groups_received),
        .groups_written(packer_groups_written)
    );

    integer bank;
    always_ff @(posedge clk) begin
        if (rst) begin
            running <= 1'b0;
            load_state <= L_IDLE;
            compute_state <= C_IDLE;
            descriptor_start <= 1'b0;
            all_descriptors_issued <= 1'b0;
            input_base_reg <= '0; output_base_reg <= '0;
            input_row_words_reg <= '0; input_row_bytes_reg <= '0;
            input_tile_stride_bytes_reg <= '0; output_row_bytes_reg <= '0;
            frame_height_reg <= '0; width_reg <= '0; tile_rows_reg <= '0;
            input_groups_reg <= '0; output_groups_reg <= '0;
            kernel_reg <= 1'b0; relu_reg <= 1'b0;
            weight_base_reg <= '0; parameter_base_reg <= '0; tokens_reg <= '0;
            next_load_bank <= 1'b1; next_compute_bank <= 1'b1;
            current_compute_bank <= 1'b0; slot_valid <= 2'b00;
            for (bank = 0; bank < 2; bank = bank + 1) begin
                slot_output_rows[bank] <= '0;
                slot_output_row_base_words[bank] <= '0;
                slot_pad_top[bank] <= 1'b0; slot_pad_bottom[bank] <= 1'b0;
                slot_last[bank] <= 1'b0; slot_tag[bank] <= '0;
                slot_pixel_count[bank] <= '0; slot_total_groups[bank] <= '0;
                slot_output_address[bank] <= '0; slot_output_bytes[bank] <= '0;
            end
            load_command_reg <= '0; load_words_reg <= '0;
            load_output_rows_reg <= '0; load_output_row_base_words_reg <= '0;
            load_pad_top_reg <= 1'b0; load_pad_bottom_reg <= 1'b0;
            load_last_reg <= 1'b0; load_tag_reg <= '0;
            load_pixel_count_reg <= '0; load_total_groups_reg <= '0;
            load_output_address_reg <= '0; load_output_bytes_reg <= '0;
            load_done_seen <= 1'b0; mm2s_status_seen <= 1'b0;
            strip_load_start <= 1'b0; strip_compute_start <= 1'b0;
            packer_start <= 1'b0; s2mm_command_reg <= '0;
            s2mm_status_seen <= 1'b0; strip_done_seen <= 1'b0;
            packer_done_seen <= 1'b0; current_last <= 1'b0; current_tag <= '0;
            done <= 1'b0; error <= 1'b0; cycle_count <= '0;
            load_wait_cycles <= '0; compute_cycles <= '0;
            output_wait_cycles <= '0; output_stall_count <= '0;
            strips_completed <= '0;
        end else begin
            descriptor_start <= 1'b0;
            strip_load_start <= 1'b0;
            strip_compute_start <= 1'b0;
            packer_start <= 1'b0;
            done <= 1'b0;

            if (running) begin
                cycle_count <= cycle_count + 1'b1;
                if (compute_state == C_IDLE && !slot_valid[next_compute_bank])
                    load_wait_cycles <= load_wait_cycles + 1'b1;
                if (compute_state == C_RUN && !(strip_done_seen || strip_done))
                    compute_cycles <= compute_cycles + 1'b1;
                if (compute_state == C_RUN && (strip_done_seen || strip_done)
                        && !compute_complete_now)
                    output_wait_cycles <= output_wait_cycles + 1'b1;
                if (m_axis_s2mm_tvalid && !m_axis_s2mm_tready)
                    output_stall_count <= output_stall_count + 1'b1;
            end

            if (start && running)
                error <= 1'b1;
            if (descriptor_error || strip_error || packer_error)
                error <= 1'b1;

            if (start && !running) begin
                if (input_row_words == 0 || input_row_bytes == 0
                        || input_tile_stride_bytes == 0 || output_row_bytes == 0
                        || frame_height == 0 || width == 0 || tile_rows == 0
                        || input_groups == 0 || output_groups == 0
                        || tokens_per_output_group == 0) begin
                    error <= 1'b1;
                end else begin
                    input_base_reg <= input_base_bytes;
                    output_base_reg <= output_base_bytes;
                    input_row_words_reg <= input_row_words;
                    input_row_bytes_reg <= input_row_bytes;
                    input_tile_stride_bytes_reg <= input_tile_stride_bytes;
                    output_row_bytes_reg <= output_row_bytes;
                    frame_height_reg <= frame_height; width_reg <= width;
                    tile_rows_reg <= tile_rows; input_groups_reg <= input_groups;
                    output_groups_reg <= output_groups; kernel_reg <= kernel_3x3;
                    relu_reg <= relu_enable; weight_base_reg <= weight_base;
                    parameter_base_reg <= parameter_base;
                    tokens_reg <= tokens_per_output_group;
                    running <= 1'b1; load_state <= L_IDLE; compute_state <= C_IDLE;
                    all_descriptors_issued <= 1'b0;
                    // The cache write bank persists across layer jobs. Start
                    // compute from the bank that the next MM2S load will fill.
                    next_compute_bank <= next_load_bank;
                    slot_valid <= 2'b00; descriptor_start <= 1'b1;
                    error <= 1'b0; cycle_count <= 0; load_wait_cycles <= 0;
                    compute_cycles <= 0; output_wait_cycles <= 0;
                    output_stall_count <= 0; strips_completed <= 0;
                end
            end

            if (descriptor_fire) begin
                load_command_reg <= descriptor_mm2s_command;
                load_words_reg <= descriptor_source_words;
                load_output_rows_reg <= descriptor_output_rows;
                load_output_row_base_words_reg <= descriptor_output_row_base_words;
                load_pad_top_reg <= descriptor_pad_top;
                load_pad_bottom_reg <= descriptor_pad_bottom;
                load_last_reg <= descriptor_last; load_tag_reg <= descriptor_tag;
                load_pixel_count_reg <= descriptor_pixels_wide[16:0];
                load_total_groups_reg <= descriptor_groups_wide[19:0];
                load_output_address_reg <= output_base_reg
                    + descriptor_output_y * output_row_bytes_reg;
                load_output_bytes_reg <= descriptor_bytes_wide[31:0];
                if (descriptor_last)
                    all_descriptors_issued <= 1'b1;
                load_state <= L_ISSUE;
            end

            case (load_state)
                L_IDLE: begin end
                L_ISSUE: if (mm2s_command_fire) begin
                    strip_load_start <= 1'b1;
                    load_done_seen <= 1'b0; mm2s_status_seen <= 1'b0;
                    load_state <= L_RUN;
                end
                L_RUN: begin
                    if (strip_load_done)
                        load_done_seen <= 1'b1;
                    if (mm2s_status_fire) begin
                        mm2s_status_seen <= 1'b1;
                        if (!s_axis_mm2s_sts_tdata[7]
                                || |s_axis_mm2s_sts_tdata[6:4]
                                || s_axis_mm2s_sts_tdata[3:0] != load_tag_reg)
                            error <= 1'b1;
                    end
                    if (load_complete_now) begin
                        slot_output_rows[next_load_bank] <= load_output_rows_reg;
                        slot_output_row_base_words[next_load_bank]
                            <= load_output_row_base_words_reg;
                        slot_pad_top[next_load_bank] <= load_pad_top_reg;
                        slot_pad_bottom[next_load_bank] <= load_pad_bottom_reg;
                        slot_last[next_load_bank] <= load_last_reg;
                        slot_tag[next_load_bank] <= load_tag_reg;
                        slot_pixel_count[next_load_bank] <= load_pixel_count_reg;
                        slot_total_groups[next_load_bank] <= load_total_groups_reg;
                        slot_output_address[next_load_bank] <= load_output_address_reg;
                        slot_output_bytes[next_load_bank] <= load_output_bytes_reg;
                        slot_valid[next_load_bank] <= 1'b1;
                        next_load_bank <= ~next_load_bank;
                        load_state <= L_IDLE;
                    end
                end
                default: load_state <= L_IDLE;
            endcase

            case (compute_state)
                C_IDLE: if (running && slot_valid[next_compute_bank]) begin
                    current_compute_bank <= next_compute_bank;
                    current_last <= slot_last[next_compute_bank];
                    current_tag <= slot_tag[next_compute_bank];
                    s2mm_command_reg <= '0;
                    s2mm_command_reg[67:64] <= slot_tag[next_compute_bank];
                    s2mm_command_reg[63:32] <= slot_output_address[next_compute_bank];
                    s2mm_command_reg[31] <= 1'b1;
                    s2mm_command_reg[30] <= 1'b1;
                    s2mm_command_reg[23] <= 1'b1;
                    s2mm_command_reg[22:0]
                        <= slot_output_bytes[next_compute_bank][22:0];
                    compute_state <= C_ISSUE;
                end
                C_ISSUE: if (s2mm_command_fire) begin
                    strip_compute_start <= 1'b1;
                    packer_start <= 1'b1;
                    strip_done_seen <= 1'b0; packer_done_seen <= 1'b0;
                    s2mm_status_seen <= 1'b0;
                    compute_state <= C_RUN;
                end
                C_RUN: begin
                    if (strip_done)
                        strip_done_seen <= 1'b1;
                    if (packer_done)
                        packer_done_seen <= 1'b1;
                    if (s2mm_status_fire) begin
                        s2mm_status_seen <= 1'b1;
                        if (!s_axis_s2mm_sts_tdata[7]
                                || |s_axis_s2mm_sts_tdata[6:4]
                                || s_axis_s2mm_sts_tdata[3:0] != current_tag)
                            error <= 1'b1;
                    end
                    if (compute_complete_now) begin
                        slot_valid[current_compute_bank] <= 1'b0;
                        strips_completed <= strips_completed + 1'b1;
                        next_compute_bank <= ~next_compute_bank;
                        compute_state <= C_IDLE;
                        if (current_last) begin
                            running <= 1'b0; done <= 1'b1;
                        end
                    end
                end
                default: compute_state <= C_IDLE;
            endcase

            if (running && watchdog_limit != 0 && cycle_count >= watchdog_limit) begin
                running <= 1'b0; done <= 1'b1; error <= 1'b1;
            end
        end
    end
endmodule
