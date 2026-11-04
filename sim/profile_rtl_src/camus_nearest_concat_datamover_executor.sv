`timescale 1ns/1ps

module camus_feature_bank #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_W = $clog2(DEPTH)
) (
    input logic clk,
    input logic write_enable,
    input logic [ADDR_W-1:0] write_address,
    input logic [63:0] write_data,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_address,
    output logic [63:0] read_data
);
    (* ram_style = "block" *) logic [63:0] memory [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule

// DDR tile executor for nearest(project) + current-frame skip concatenation.
// A and B are loaded sequentially through one MM2S channel, then both remain
// in BRAM while nearest address repetition and rescaling generate the output.
module camus_nearest_concat_datamover_executor #(
    parameter integer CACHE_DEPTH = 4096,
    parameter integer ADDR_W = $clog2(CACHE_DEPTH)
) (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] project_base_bytes,
    input logic [31:0] skip_base_bytes,
    input logic [31:0] output_base_bytes,
    input logic [8:0] low_width, input logic [8:0] low_height,
    input logic [5:0] project_channels, input logic [5:0] skip_channels,
    input logic [8:0] tile_low_rows,
    input logic signed [31:0] project_multiplier,
    input logic signed [6:0] project_shift,
    input logic signed [31:0] skip_multiplier,
    input logic signed [6:0] skip_shift,
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
    output logic [63:0] cycle_count,
    output logic [15:0] tiles_completed
);
    typedef enum logic [3:0] {
        S_IDLE, S_PREP, S_ISSUE_A, S_LOAD_A, S_ISSUE_B, S_LOAD_B,
        S_PREP_OUT, S_ISSUE_OUT, S_STREAM, S_WAIT_TILE
    } state_t;
    state_t state;

    logic [8:0] low_width_reg, low_height_reg, tile_rows_reg;
    logic [5:0] a_channels_reg, b_channels_reg;
    logic [2:0] a_groups, b_groups, output_groups;
    logic signed [31:0] a_multiplier_reg, b_multiplier_reg;
    logic signed [6:0] a_shift_reg, b_shift_reg;
    logic [31:0] a_base_reg, b_base_reg, out_base_reg;
    logic [71:0] mm2s_a_cmd_reg, mm2s_b_cmd_reg;
    logic [71:0] s2mm_cmd_reg;
    logic [8:0] tile_y, current_low_rows;
    logic [9:0] high_width, current_high_rows;
    logic [12:0] a_words_reg, b_words_reg;
    logic [13:0] output_words_reg;
    logic [22:0] a_bytes_reg, b_bytes_reg, output_bytes_reg;
    logic [ADDR_W:0] load_word_count;
    logic [3:0] active_tag;
    logic load_data_done, mm_status_seen, output_data_done, s2_status_seen;

    logic split_input_ready, split_valid, split_ready, split_last, split_error;
    logic [63:0] split_data;
    logic [63:0] a_read_data, b_read_data;
    logic [ADDR_W-1:0] a_read_address, b_read_address;
    logic a_read_enable, b_read_enable;
    logic [20:0] pixel_index, total_pixels_reg;
    logic [13:0] request_count;
    logic [2:0] group_index;
    logic [9:0] high_x, high_y;
    logic [20:0] a_row_base, a_pixel_cursor;
    logic [20:0] a_group_base, b_group_base;

    logic issue_request, dense_4_plus_4, request_is_a, request_is_b;
    logic request_pending, pending_is_a, pending_is_b, pending_dense, pending_last;
    logic rescale_valid, rescale_ready, rescale_ready_out, rescale_last;
    logic [63:0] rescale_input_data, rescale_data;
    logic signed [31:0] rescale_low_multiplier, rescale_high_multiplier;
    logic signed [6:0] rescale_low_shift, rescale_high_shift;
    logic [3:0] rescale_split_lane;
    logic rescale_pipe_valid, rescale_pipe_ready, rescale_pipe_last;
    logic [63:0] rescale_pipe_data;
    logic signed [31:0] rescale_pipe_low_multiplier,rescale_pipe_high_multiplier;
    logic signed [6:0] rescale_pipe_low_shift,rescale_pipe_high_shift;
    logic [3:0] rescale_pipe_split_lane;
    logic pack_error;

    assign busy = state != S_IDLE;
    assign high_width = low_width_reg << 1;
    assign current_high_rows = current_low_rows << 1;
    assign a_groups = (a_channels_reg + 7) >> 3;
    assign b_groups = (b_channels_reg + 7) >> 3;
    assign output_groups = (a_channels_reg + b_channels_reg + 7) >> 3;
    // All frozen group counts are one or two SIMD8 words. Explicit shifts
    // avoid synthesizing generic multipliers/dividers into the BRAM address path.
    assign a_group_base = a_groups == 1 ? a_pixel_cursor : a_pixel_cursor << 1;
    assign b_group_base = b_groups == 1 ? pixel_index : pixel_index << 1;
    assign dense_4_plus_4 = a_channels_reg == 4 && b_channels_reg == 4;
    assign request_is_a = !dense_4_plus_4 && group_index < a_groups;
    assign request_is_b = !dense_4_plus_4 && !request_is_a;
    assign a_read_address = a_group_base + (request_is_a ? group_index : 0);
    assign b_read_address = b_group_base + (request_is_b ? group_index-a_groups : 0);
    assign issue_request = state == S_STREAM
        && (!request_pending || rescale_pipe_ready)
        && request_count < output_words_reg;
    assign rescale_pipe_ready = !rescale_pipe_valid || rescale_ready;

    // Command buses are driven only by precomputed registers. Keeping address,
    // length, tag, and control bits off the live command interface prevents the
    // command FIFO timing path from including tile arithmetic or command muxing.
    always_comb begin
        if (state == S_ISSUE_B)
            m_axis_mm2s_cmd_tdata = mm2s_b_cmd_reg;
        else
            m_axis_mm2s_cmd_tdata = mm2s_a_cmd_reg;
        m_axis_s2mm_cmd_tdata = s2mm_cmd_reg;
    end

    assign m_axis_mm2s_cmd_tvalid = state == S_ISSUE_A || state == S_ISSUE_B;
    assign m_axis_s2mm_cmd_tvalid = state == S_ISSUE_OUT;
    assign s_axis_mm2s_sts_tready = (state == S_LOAD_A || state == S_LOAD_B)
        && !mm_status_seen;
    assign s_axis_s2mm_sts_tready = state == S_WAIT_TILE && !s2_status_seen;
    assign s_axis_mm2s_tready = (state == S_LOAD_A || state == S_LOAD_B)
        && split_input_ready;
    assign split_ready = state == S_LOAD_A || state == S_LOAD_B;

    camus_axis128_to_axis64 u_split (
        .clk,.rst,.s_valid(s_axis_mm2s_tvalid
            && (state == S_LOAD_A || state == S_LOAD_B)),
        .s_ready(split_input_ready),.s_data(s_axis_mm2s_tdata),
        .s_keep(s_axis_mm2s_tkeep),.s_last(s_axis_mm2s_tlast),
        .m_valid(split_valid),.m_ready(split_ready),.m_data(split_data),
        .m_last(split_last),.error(split_error));

    camus_feature_bank #(.DEPTH(CACHE_DEPTH)) u_a_bank (
        .clk,.write_enable(split_valid && split_ready && state == S_LOAD_A),
        .write_address(load_word_count[ADDR_W-1:0]),.write_data(split_data),
        .read_enable(a_read_enable),.read_address(a_read_address),.read_data(a_read_data));
    camus_feature_bank #(.DEPTH(CACHE_DEPTH)) u_b_bank (
        .clk,.write_enable(split_valid && split_ready && state == S_LOAD_B),
        .write_address(load_word_count[ADDR_W-1:0]),.write_data(split_data),
        .read_enable(b_read_enable),.read_address(b_read_address),.read_data(b_read_data));

    always_comb begin
        if (pending_dense) begin
            rescale_input_data = {b_read_data[31:0], a_read_data[31:0]};
            rescale_low_multiplier = a_multiplier_reg;
            rescale_low_shift = a_shift_reg;
            rescale_high_multiplier = b_multiplier_reg;
            rescale_high_shift = b_shift_reg;
            rescale_split_lane = 4;
        end else if (pending_is_a) begin
            rescale_input_data = a_read_data;
            rescale_low_multiplier = a_multiplier_reg;
            rescale_low_shift = a_shift_reg;
            rescale_high_multiplier = a_multiplier_reg;
            rescale_high_shift = a_shift_reg;
            rescale_split_lane = 8;
        end else begin
            rescale_input_data = b_read_data;
            rescale_low_multiplier = b_multiplier_reg;
            rescale_low_shift = b_shift_reg;
            rescale_high_multiplier = b_multiplier_reg;
            rescale_high_shift = b_shift_reg;
            rescale_split_lane = 8;
        end
    end

    camus_rescale_group_axis u_rescale (
        .clk,.rst,.s_valid(rescale_pipe_valid),.s_ready(rescale_ready),
        .s_data(rescale_pipe_data),.low_multiplier(rescale_pipe_low_multiplier),
        .low_shift(rescale_pipe_low_shift),.high_multiplier(rescale_pipe_high_multiplier),
        .high_shift(rescale_pipe_high_shift),.split_lane(rescale_pipe_split_lane),
        .s_last(rescale_pipe_last),.m_valid(rescale_valid),.m_ready(rescale_ready_out),
        .m_data(rescale_data),.m_last(rescale_last));

    camus_axis64_to_axis128 u_pack (
        .clk,.rst,.s_valid(rescale_valid),.s_ready(rescale_ready_out),
        .s_data(rescale_data),.s_last(rescale_last),.m_valid(m_axis_s2mm_tvalid),
        .m_ready(m_axis_s2mm_tready),.m_data(m_axis_s2mm_tdata),
        .m_keep(m_axis_s2mm_tkeep),.m_last(m_axis_s2mm_tlast),.error(pack_error));

    always_comb begin
        a_read_enable = issue_request && (dense_4_plus_4 || request_is_a);
        b_read_enable = issue_request && (dense_4_plus_4 || request_is_b);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; error<=0; cycle_count<=0; tiles_completed<=0;
            low_width_reg<=0; low_height_reg<=0; tile_rows_reg<=0;
            a_channels_reg<=0; b_channels_reg<=0; a_multiplier_reg<=0;
            b_multiplier_reg<=0; a_shift_reg<=0; b_shift_reg<=0;
            a_base_reg<=0; b_base_reg<=0; out_base_reg<=0;
            mm2s_a_cmd_reg<=0; mm2s_b_cmd_reg<=0; s2mm_cmd_reg<=0; tile_y<=0;
            current_low_rows<=0; load_word_count<=0; active_tag<=0;
            a_words_reg<=0; b_words_reg<=0; output_words_reg<=0;
            a_bytes_reg<=0; b_bytes_reg<=0; output_bytes_reg<=0;
            total_pixels_reg<=0;
            load_data_done<=0; mm_status_seen<=0; output_data_done<=0;
            s2_status_seen<=0; pixel_index<=0; request_count<=0; group_index<=0;
            request_pending<=0; pending_is_a<=0; pending_is_b<=0;
            pending_dense<=0; pending_last<=0;
            high_x<=0; high_y<=0; a_row_base<=0; a_pixel_cursor<=0;
            rescale_pipe_valid<=0; rescale_pipe_last<=0; rescale_pipe_data<=0;
            rescale_pipe_low_multiplier<=0; rescale_pipe_high_multiplier<=0;
            rescale_pipe_low_shift<=0; rescale_pipe_high_shift<=0;
            rescale_pipe_split_lane<=0;
        end else begin
            done<=0;
            if (busy) cycle_count<=cycle_count+1'b1;
            if (split_error || pack_error) error<=1'b1;
            if (start && busy) error<=1'b1;

            if ((state==S_LOAD_A || state==S_LOAD_B)
                    && s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready) begin
                mm_status_seen<=1'b1;
                if (!s_axis_mm2s_sts_tdata[7] || |s_axis_mm2s_sts_tdata[6:4]
                        || s_axis_mm2s_sts_tdata[3:0]!=active_tag)
                    error<=1'b1;
            end
            if (state==S_WAIT_TILE && s_axis_s2mm_sts_tvalid
                    && s_axis_s2mm_sts_tready) begin
                s2_status_seen<=1'b1;
                if (!s_axis_s2mm_sts_tdata[7] || |s_axis_s2mm_sts_tdata[6:4]
                        || s_axis_s2mm_sts_tdata[3:0]!=active_tag)
                    error<=1'b1;
            end
            if (split_valid && split_ready) begin
                load_word_count<=load_word_count+1'b1;
                if (split_last) load_data_done<=1'b1;
            end
            if (m_axis_s2mm_tvalid && m_axis_s2mm_tready && m_axis_s2mm_tlast)
                output_data_done<=1'b1;
            if (rescale_pipe_ready) begin
                rescale_pipe_valid<=request_pending;
                if (request_pending) begin
                    rescale_pipe_data<=rescale_input_data;
                    rescale_pipe_low_multiplier<=rescale_low_multiplier;
                    rescale_pipe_high_multiplier<=rescale_high_multiplier;
                    rescale_pipe_low_shift<=rescale_low_shift;
                    rescale_pipe_high_shift<=rescale_high_shift;
                    rescale_pipe_split_lane<=rescale_split_lane;
                    rescale_pipe_last<=pending_last;
                end
            end

            case(state)
                S_IDLE: if(start) begin
                    if(low_width==0 || low_height==0 || tile_low_rows==0
                            || project_channels==0 || skip_channels==0
                            || project_channels>16 || skip_channels>16) begin
                        error<=1'b1; done<=1'b1;
                    end else begin
                        low_width_reg<=low_width; low_height_reg<=low_height;
                        tile_rows_reg<=tile_low_rows; a_channels_reg<=project_channels;
                        b_channels_reg<=skip_channels; a_multiplier_reg<=project_multiplier;
                        a_shift_reg<=project_shift; b_multiplier_reg<=skip_multiplier;
                        b_shift_reg<=skip_shift; a_base_reg<=project_base_bytes;
                        b_base_reg<=skip_base_bytes; out_base_reg<=output_base_bytes;
                        tile_y<=0; current_low_rows<=tile_low_rows>low_height
                            ? low_height : tile_low_rows;
                        active_tag<=0; tiles_completed<=0; cycle_count<=0; error<=0;
                        state<=S_PREP;
                    end
                end
                S_PREP: begin
                    a_words_reg<=current_low_rows*low_width_reg*a_groups;
                    b_words_reg<=current_high_rows*high_width*b_groups;
                    output_words_reg<=current_high_rows*high_width*output_groups;
                    a_bytes_reg<=(current_low_rows*low_width_reg*a_groups)<<3;
                    b_bytes_reg<=(current_high_rows*high_width*b_groups)<<3;
                    output_bytes_reg<=(current_high_rows*high_width*output_groups)<<3;
                    total_pixels_reg<=current_high_rows*high_width;

                    // Build both input commands one cycle before either command
                    // is exposed to the DataMover FIFO.
                    mm2s_a_cmd_reg <= '0;
                    mm2s_a_cmd_reg[67:64] <= active_tag;
                    mm2s_a_cmd_reg[63:32] <= a_base_reg
                        + tile_y * low_width_reg * a_groups * 8;
                    mm2s_a_cmd_reg[31] <= 1'b1;
                    mm2s_a_cmd_reg[30] <= 1'b1;
                    mm2s_a_cmd_reg[23] <= 1'b1;
                    mm2s_a_cmd_reg[22:0] <= (current_low_rows*low_width_reg*a_groups)<<3;

                    mm2s_b_cmd_reg <= '0;
                    mm2s_b_cmd_reg[67:64] <= active_tag + 1'b1;
                    mm2s_b_cmd_reg[63:32] <= b_base_reg
                        + (tile_y << 1) * high_width * b_groups * 8;
                    mm2s_b_cmd_reg[31] <= 1'b1;
                    mm2s_b_cmd_reg[30] <= 1'b1;
                    mm2s_b_cmd_reg[23] <= 1'b1;
                    mm2s_b_cmd_reg[22:0] <= (current_high_rows*high_width*b_groups)<<3;
                    state<=S_ISSUE_A;
                end
                S_ISSUE_A: if(m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready) begin
                    load_word_count<=0; load_data_done<=0; mm_status_seen<=0;
                    state<=S_LOAD_A;
                end
                S_LOAD_A: if((load_data_done||split_valid&&split_ready&&split_last)
                        && (mm_status_seen||s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready)) begin
                    active_tag<=active_tag+1'b1; state<=S_ISSUE_B;
                end
                S_ISSUE_B: if(m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready) begin
                    load_word_count<=0; load_data_done<=0; mm_status_seen<=0;
                    state<=S_LOAD_B;
                end
                S_LOAD_B: if((load_data_done||split_valid&&split_ready&&split_last)
                        && (mm_status_seen||s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready)) begin
                    active_tag<=active_tag+1'b1; state<=S_PREP_OUT;
                end
                S_PREP_OUT: begin
                    // Register the full command so address arithmetic cannot feed
                    // the DataMover command FIFO in the same cycle.
                    s2mm_cmd_reg <= '0;
                    s2mm_cmd_reg[67:64] <= active_tag;
                    s2mm_cmd_reg[63:32] <= out_base_reg
                        + (tile_y << 1) * high_width * output_groups * 8;
                    s2mm_cmd_reg[31] <= 1'b1;
                    s2mm_cmd_reg[30] <= 1'b1;
                    s2mm_cmd_reg[23] <= 1'b1;
                    s2mm_cmd_reg[22:0] <= output_bytes_reg;
                    state <= S_ISSUE_OUT;
                end
                S_ISSUE_OUT: if(m_axis_s2mm_cmd_tvalid&&m_axis_s2mm_cmd_tready) begin
                    pixel_index<=0; high_x<=0; high_y<=0;
                    a_row_base<=0; a_pixel_cursor<=0;
                    request_count<=0; group_index<=0; request_pending<=0;
                    output_data_done<=0; s2_status_seen<=0;
                    state<=S_STREAM;
                end
                S_STREAM: begin
                    if(request_pending && rescale_pipe_ready)
                        request_pending<=1'b0;
                    if(issue_request) begin
                        request_pending<=1'b1;
                        pending_is_a<=request_is_a;
                        pending_is_b<=request_is_b;
                        pending_dense<=dense_4_plus_4;
                        pending_last<=request_count==output_words_reg-1'b1;
                        request_count<=request_count+1'b1;
                        if(group_index==output_groups-1'b1) begin
                            group_index<=0;
                            pixel_index<=pixel_index+1'b1;
                            if(pixel_index!=total_pixels_reg-1'b1) begin
                        if(high_x==high_width-1'b1) begin
                            high_x<=0;
                            high_y<=high_y+1'b1;
                            if(high_y[0]) begin
                                a_row_base<=a_row_base+low_width_reg;
                                a_pixel_cursor<=a_row_base+low_width_reg;
                            end else begin
                                a_pixel_cursor<=a_row_base;
                            end
                        end else begin
                            high_x<=high_x+1'b1;
                            if(high_x[0]) a_pixel_cursor<=a_pixel_cursor+1'b1;
                        end
                            end
                        end else begin
                            group_index<=group_index+1'b1;
                        end
                    end
                    if(request_count==output_words_reg && !request_pending)
                        state<=S_WAIT_TILE;
                end
                S_WAIT_TILE: if((output_data_done||m_axis_s2mm_tvalid&&m_axis_s2mm_tready&&m_axis_s2mm_tlast)
                        && (s2_status_seen||s_axis_s2mm_sts_tvalid&&s_axis_s2mm_sts_tready)) begin
                    tiles_completed<=tiles_completed+1'b1;
                    if(tile_y+current_low_rows>=low_height_reg) begin
                        done<=1'b1; state<=S_IDLE;
                    end else begin
                        tile_y<=tile_y+current_low_rows;
                        current_low_rows<=tile_rows_reg>low_height_reg-(tile_y+current_low_rows)
                            ? low_height_reg-(tile_y+current_low_rows) : tile_rows_reg;
                        active_tag<=active_tag+1'b1; state<=S_PREP;
                    end
                end
                default: state<=S_IDLE;
            endcase
            if(watchdog_limit!=0 && busy && cycle_count>=watchdog_limit) begin
                error<=1'b1; done<=1'b1; state<=S_IDLE;
            end
        end
    end
endmodule
