`timescale 1ns/1ps

// Converts an NHWC feature map packed as one 64-bit SIMD8 word per
// (pixel,input-group) into the token order consumed by camus_w4a8_layer_engine.
// The feature read port is a one-cycle synchronous memory interface.
module camus_window_token_source #(
    parameter integer FEATURE_ADDR_W = 20,
    parameter integer SIMD = 8
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [FEATURE_ADDR_W-1:0] feature_base,
    input  logic [FEATURE_ADDR_W-1:0] row_stride_words,
    input  logic [8:0] height,
    input  logic [8:0] width,
    input  logic [3:0] input_groups,
    input  logic [3:0] output_groups,
    input  logic kernel_3x3,
    input  logic [FEATURE_ADDR_W-1:0] output_row_base_words,
    input  logic pad_top,
    input  logic pad_bottom,
    input  logic pad_left,
    input  logic pad_right,

    output logic feature_read_enable,
    output logic [FEATURE_ADDR_W-1:0] feature_read_address,
    input  logic [SIMD*8-1:0] feature_read_data,

    output logic activation_valid,
    output logic [SIMD*8-1:0] activation_u8,
    input  logic activation_ready,

    output logic busy,
    output logic done,
    output logic error
);
    logic [FEATURE_ADDR_W-1:0] base_reg;
    logic [FEATURE_ADDR_W-1:0] stride_reg;
    logic [8:0] height_reg, width_reg;
    logic [3:0] input_groups_reg, output_groups_reg;
    logic kernel_3x3_reg;
    logic pad_top_reg, pad_bottom_reg, pad_left_reg, pad_right_reg;

    logic [8:0] pixel_y, pixel_x;
    logic [FEATURE_ADDR_W-1:0] row_base_words;
    logic [FEATURE_ADDR_W-1:0] pixel_x_words;
    logic [3:0] output_group;
    logic [1:0] kernel_y, kernel_x;
    logic [3:0] input_group;
    logic issuing_done;

    logic request_valid_d;
    logic request_padding_d;
    logic request_last_d;
    logic output_last;

    logic pipeline_advance;
    logic issue_fire;
    logic issue_padding;
    logic issue_last;
    logic y_top, y_bottom, x_left, x_right;
    logic [FEATURE_ADDR_W-1:0] issue_row_address;
    logic [FEATURE_ADDR_W-1:0] issue_column_address;
    logic [3:0] input_step;
    assign input_step = (SIMD == 16 && input_groups_reg > 1) ? 4'd2 : 4'd1;

    assign pipeline_advance = !activation_valid || activation_ready;
    assign issue_fire = busy && !issuing_done && pipeline_advance;

    always_comb begin
        y_top = kernel_3x3_reg && pad_top_reg && kernel_y == 0 && pixel_y == 0;
        y_bottom = kernel_3x3_reg && pad_bottom_reg && kernel_y == 2
            && pixel_y == height_reg - 1'b1;
        x_left = kernel_3x3_reg && pad_left_reg && kernel_x == 0 && pixel_x == 0;
        x_right = kernel_3x3_reg && pad_right_reg && kernel_x == 2
            && pixel_x == width_reg - 1'b1;
        issue_padding = y_top || y_bottom || x_left || x_right;

        issue_row_address = row_base_words;
        issue_column_address = pixel_x_words;
        if (kernel_3x3_reg) begin
            if (kernel_y == 0)
                issue_row_address = row_base_words - stride_reg;
            else if (kernel_y == 2)
                issue_row_address = row_base_words + stride_reg;
            if (kernel_x == 0)
                issue_column_address = pixel_x_words - input_groups_reg;
            else if (kernel_x == 2)
                issue_column_address = pixel_x_words + input_groups_reg;
        end

        feature_read_enable = issue_fire && !issue_padding;
        feature_read_address = base_reg + issue_row_address
            + issue_column_address + input_group;
        issue_last = pixel_y == height_reg - 1'b1
            && pixel_x == width_reg - 1'b1
            && output_group == output_groups_reg - 1'b1
            && input_group == input_groups_reg - input_step
            && (!kernel_3x3_reg || (kernel_y == 2 && kernel_x == 2));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            base_reg <= '0;
            stride_reg <= '0;
            height_reg <= '0;
            width_reg <= '0;
            input_groups_reg <= '0;
            output_groups_reg <= '0;
            kernel_3x3_reg <= 1'b0;
            pad_top_reg <= 1'b0;
            pad_bottom_reg <= 1'b0;
            pad_left_reg <= 1'b0;
            pad_right_reg <= 1'b0;
            pixel_y <= '0;
            pixel_x <= '0;
            row_base_words <= '0;
            pixel_x_words <= '0;
            output_group <= '0;
            kernel_y <= '0;
            kernel_x <= '0;
            input_group <= '0;
            issuing_done <= 1'b0;
            request_valid_d <= 1'b0;
            request_padding_d <= 1'b0;
            request_last_d <= 1'b0;
            activation_valid <= 1'b0;
            activation_u8 <= '0;
            output_last <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && busy)
                error <= 1'b1;

            if (start && !busy) begin
                if (height == 0 || width == 0 || input_groups == 0
                        || output_groups == 0 || row_stride_words == 0
                        || (SIMD == 16 && input_groups > 1 && input_groups[0])) begin
                    error <= 1'b1;
                end else begin
                    base_reg <= feature_base;
                    stride_reg <= row_stride_words;
                    height_reg <= height;
                    width_reg <= width;
                    input_groups_reg <= input_groups;
                    output_groups_reg <= output_groups;
                    kernel_3x3_reg <= kernel_3x3;
                    pad_top_reg <= pad_top;
                    pad_bottom_reg <= pad_bottom;
                    pad_left_reg <= pad_left;
                    pad_right_reg <= pad_right;
                    pixel_y <= 0;
                    pixel_x <= 0;
                    row_base_words <= output_row_base_words;
                    pixel_x_words <= 0;
                    output_group <= 0;
                    kernel_y <= kernel_3x3 ? 0 : 1;
                    kernel_x <= kernel_3x3 ? 0 : 1;
                    input_group <= 0;
                    issuing_done <= 1'b0;
                    request_valid_d <= 1'b0;
                    request_padding_d <= 1'b0;
                    request_last_d <= 1'b0;
                    activation_valid <= 1'b0;
                    output_last <= 1'b0;
                    busy <= 1'b1;
                    error <= 1'b0;
                end
            end else if (busy) begin
                if (activation_valid && activation_ready && output_last) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    activation_valid <= 1'b0;
                    output_last <= 1'b0;
                end else if (pipeline_advance) begin
                    activation_valid <= request_valid_d;
                    activation_u8 <= request_padding_d ? '0 : feature_read_data;
                    output_last <= request_last_d;
                    request_valid_d <= issue_fire;
                    request_padding_d <= issue_padding;
                    request_last_d <= issue_last;

                    if (issue_fire) begin
                        if (issue_last) begin
                            issuing_done <= 1'b1;
                        end else if (input_group != input_groups_reg - input_step) begin
                            input_group <= input_group + input_step;
                        end else begin
                            input_group <= 0;
                            if (kernel_3x3_reg && kernel_x != 2) begin
                                kernel_x <= kernel_x + 1'b1;
                            end else if (kernel_3x3_reg && kernel_y != 2) begin
                                kernel_x <= 0;
                                kernel_y <= kernel_y + 1'b1;
                            end else begin
                                kernel_y <= kernel_3x3_reg ? 0 : 1;
                                kernel_x <= kernel_3x3_reg ? 0 : 1;
                                if (output_group != output_groups_reg - 1'b1) begin
                                    output_group <= output_group + 1'b1;
                                end else begin
                                    output_group <= 0;
                                    if (pixel_x != width_reg - 1'b1) begin
                                        pixel_x <= pixel_x + 1'b1;
                                        pixel_x_words <= pixel_x_words + input_groups_reg;
                                    end else begin
                                        pixel_x <= 0;
                                        pixel_x_words <= 0;
                                        pixel_y <= pixel_y + 1'b1;
                                        row_base_words <= row_base_words + stride_reg;
                                    end
                                end
                            end
                        end
                    end
                end
            end else begin
                activation_valid <= 1'b0;
                request_valid_d <= 1'b0;
            end
        end
    end
endmodule
