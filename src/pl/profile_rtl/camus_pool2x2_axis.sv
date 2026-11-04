`timescale 1ns/1ps

module camus_pool_line_bank #(
    parameter integer DEPTH = 256,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input logic clk,
    input logic enable,
    input logic [ADDR_W-1:0] address,
    input logic [63:0] write_data,
    output logic [63:0] read_data
);
    (* ram_style = "block" *) logic [63:0] memory [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (enable) begin
            read_data <= memory[address];
            memory[address] <= write_data;
        end
    end
endmodule

// Raster-order 2x2 max-pool for packed UINT8 SIMD8 feature words.
// Words for one pixel are contiguous. The line store keeps the previous row;
// one registered read stage preserves a one-word/cycle steady-state input.
module camus_pool2x2_axis #(
    parameter integer MAX_WIDTH = 256,
    parameter integer MAX_GROUPS = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [8:0] width,
    input  logic [8:0] height,
    input  logic [2:0] groups,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_data,
    input  logic s_last,

    output logic m_valid,
    input  logic m_ready,
    output logic [63:0] m_data,
    output logic m_last,

    output logic busy,
    output logic done,
    output logic error
);
    localparam integer X_ADDR_W = (MAX_WIDTH <= 1) ? 1 : $clog2(MAX_WIDTH);

    logic [63:0] line_read_data [0:MAX_GROUPS-1];
    logic [63:0] left_current [0:MAX_GROUPS-1];
    logic [63:0] left_previous [0:MAX_GROUPS-1];

    logic [8:0] width_reg, height_reg;
    logic [2:0] groups_reg;
    logic [8:0] in_x, in_y;
    logic [2:0] in_group;

    logic pipe_valid;
    logic [63:0] pipe_current, pipe_left_current;
    logic [8:0] pipe_x, pipe_y;
    logic [2:0] pipe_group;
    logic pipe_input_last;
    logic pipe_emit;
    logic pipe_last_output;
    logic pipe_advance;
    logic input_fire;

    integer lane;
    integer g;
    logic [7:0] max_top, max_bottom;

    assign pipe_emit = pipe_valid && pipe_x[0] && pipe_y[0];
    assign pipe_last_output = pipe_emit
        && pipe_x == width_reg - 1'b1
        && pipe_y == height_reg - 1'b1
        && pipe_group == groups_reg - 1'b1;
    assign pipe_advance = pipe_valid
        && (!pipe_emit || !m_valid || m_ready);
    assign s_ready = busy && (!pipe_valid || pipe_advance);
    assign input_fire = s_valid && s_ready;
    genvar bank;
    generate
        for (bank = 0; bank < MAX_GROUPS; bank = bank + 1) begin : g_line_bank
            camus_pool_line_bank #(
                .DEPTH(MAX_WIDTH), .ADDR_W(X_ADDR_W)
            ) u_bank (
                .clk(clk),
                .enable(input_fire && in_group == bank),
                .address(in_x[X_ADDR_W-1:0]),
                .write_data(s_data),
                .read_data(line_read_data[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            width_reg <= '0;
            height_reg <= '0;
            groups_reg <= '0;
            in_x <= '0;
            in_y <= '0;
            in_group <= '0;
            pipe_valid <= 1'b0;
            pipe_current <= '0;
            pipe_left_current <= '0;
            pipe_x <= '0;
            pipe_y <= '0;
            pipe_group <= '0;
            pipe_input_last <= 1'b0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_last <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            for (g = 0; g < MAX_GROUPS; g = g + 1) begin
                left_current[g] <= '0;
                left_previous[g] <= '0;
            end
        end else begin
            done <= 1'b0;

            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
                if (m_last) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end

            if (start) begin
                if (busy || width == 0 || height == 0 || width[0]
                        || height[0] || groups == 0 || groups > MAX_GROUPS) begin
                    error <= 1'b1;
                end else begin
                    width_reg <= width;
                    height_reg <= height;
                    groups_reg <= groups;
                    in_x <= 0;
                    in_y <= 0;
                    in_group <= 0;
                    pipe_valid <= 1'b0;
                    m_valid <= 1'b0;
                    busy <= 1'b1;
                    error <= 1'b0;
                    for (g = 0; g < MAX_GROUPS; g = g + 1) begin
                        left_current[g] <= '0;
                        left_previous[g] <= '0;
                    end
                end
            end else if (busy) begin
                if (pipe_advance) begin
                    if (pipe_emit) begin
                        for (lane = 0; lane < 8; lane = lane + 1) begin
                            max_top = left_previous[pipe_group][lane*8 +: 8]
                                    > line_read_data[pipe_group][lane*8 +: 8]
                                ? left_previous[pipe_group][lane*8 +: 8]
                                : line_read_data[pipe_group][lane*8 +: 8];
                            max_bottom = pipe_left_current[lane*8 +: 8] > pipe_current[lane*8 +: 8]
                                ? pipe_left_current[lane*8 +: 8] : pipe_current[lane*8 +: 8];
                            m_data[lane*8 +: 8] <= max_top > max_bottom ? max_top : max_bottom;
                        end
                        m_valid <= 1'b1;
                        m_last <= pipe_last_output;
                    end
                    left_previous[pipe_group] <= line_read_data[pipe_group];
                    if (!input_fire)
                        pipe_valid <= 1'b0;
                end

                if (input_fire) begin
                    pipe_valid <= 1'b1;
                    pipe_current <= s_data;
                    pipe_left_current <= left_current[in_group];
                    pipe_x <= in_x;
                    pipe_y <= in_y;
                    pipe_group <= in_group;
                    pipe_input_last <= s_last;

                    left_current[in_group] <= s_data;

                    if (s_last != (in_x == width_reg - 1'b1
                            && in_y == height_reg - 1'b1
                            && in_group == groups_reg - 1'b1))
                        error <= 1'b1;

                    if (in_group == groups_reg - 1'b1) begin
                        in_group <= 0;
                        if (in_x == width_reg - 1'b1) begin
                            in_x <= 0;
                            in_y <= in_y + 1'b1;
                        end else begin
                            in_x <= in_x + 1'b1;
                        end
                    end else begin
                        in_group <= in_group + 1'b1;
                    end
                end
            end
        end
    end
endmodule
