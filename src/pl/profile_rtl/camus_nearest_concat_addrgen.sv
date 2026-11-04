`timescale 1ns/1ps

// Address generator for the exact decoder rewrite:
// nearest(x) -> 1x1(x) == nearest(1x1(x)). The project convolution therefore
// runs at the lower resolution, while this unit repeats its read address and
// pairs it with the full-resolution skip address.
module camus_nearest_concat_addrgen (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [8:0] low_width,
    input  logic [8:0] low_height,
    input  logic [2:0] project_groups,
    input  logic [2:0] skip_groups,
    output logic request_valid,
    input  logic request_ready,
    output logic request_skip,
    output logic [19:0] request_word_address,
    output logic [2:0] output_group,
    output logic output_last,
    output logic busy,
    output logic done,
    output logic error
);
    logic [9:0] high_x, high_y;
    logic [2:0] source_group;
    logic source_skip;
    logic [9:0] high_width, high_height;
    logic [19:0] project_pixel, skip_pixel;
    logic request_fire;

    assign high_width = low_width << 1;
    assign high_height = low_height << 1;
    assign project_pixel = (high_y[9:1] * low_width) + high_x[9:1];
    assign skip_pixel = (high_y * high_width) + high_x;
    assign request_valid = busy;
    assign request_skip = source_skip;
    assign request_word_address = source_skip
        ? skip_pixel * skip_groups + source_group
        : project_pixel * project_groups + source_group;
    assign output_group = source_skip ? project_groups + source_group : source_group;
    assign output_last = source_skip
        && source_group == skip_groups - 1'b1
        && high_x == high_width - 1'b1
        && high_y == high_height - 1'b1;
    assign request_fire = request_valid && request_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            high_x <= '0;
            high_y <= '0;
            source_group <= '0;
            source_skip <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                if (busy || low_width == 0 || low_height == 0
                        || project_groups == 0 || skip_groups == 0) begin
                    error <= 1'b1;
                end else begin
                    high_x <= 0;
                    high_y <= 0;
                    source_group <= 0;
                    source_skip <= 1'b0;
                    busy <= 1'b1;
                    error <= 1'b0;
                end
            end else if (request_fire) begin
                if (!source_skip) begin
                    if (source_group == project_groups - 1'b1) begin
                        source_group <= 0;
                        source_skip <= 1'b1;
                    end else begin
                        source_group <= source_group + 1'b1;
                    end
                end else if (source_group == skip_groups - 1'b1) begin
                    source_group <= 0;
                    source_skip <= 1'b0;
                    if (high_x == high_width - 1'b1) begin
                        high_x <= 0;
                        if (high_y == high_height - 1'b1) begin
                            high_y <= 0;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            high_y <= high_y + 1'b1;
                        end
                    end else begin
                        high_x <= high_x + 1'b1;
                    end
                end else begin
                    source_group <= source_group + 1'b1;
                end
            end
        end
    end
endmodule
