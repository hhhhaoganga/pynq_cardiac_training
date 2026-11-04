`timescale 1ns/1ps

// Packs PE4 output groups (four INT8 channels) into a 128-bit AXI stream.
// The FIFO absorbs S2MM backpressure; output_capacity pauses new convolution
// tokens early enough to drain the MVU pipeline before the FIFO can overflow.
module camus_output_axis_packer #(
    parameter integer FIFO_DEPTH = 32,
    parameter integer PIPELINE_RESERVE = 12,
    parameter integer PTR_W = $clog2(FIFO_DEPTH)
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [19:0] total_groups,
    input  logic [3:0] groups_per_pixel,

    input  logic in_valid,
    input  logic [31:0] in_q8,
    output logic output_capacity,

    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tlast,

    output logic busy,
    output logic done,
    output logic error,
    output logic [19:0] groups_received,
    output logic [19:0] groups_written
);
    logic [127:0] fifo_data [0:FIFO_DEPTH-1];
    logic [15:0] fifo_keep [0:FIFO_DEPTH-1];
    logic fifo_last [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] fifo_head, fifo_tail;
    logic [PTR_W:0] fifo_count;

    logic [127:0] assembly_data;
    logic [15:0] assembly_keep;
    logic [1:0] assembly_lane;
    logic [19:0] total_groups_reg;
    logic pad_half_word;
    logic [127:0] completed_data;
    logic [15:0] completed_keep;
    logic last_input, push, pop, push_ok;

    always_comb begin
        completed_data = assembly_data;
        completed_keep = assembly_keep;
        completed_data[assembly_lane*32 +: 32] = in_q8;
        completed_keep[assembly_lane*4 +: 4] = 4'hf;
        if (pad_half_word) begin
            completed_data[(assembly_lane+1'b1)*32 +: 32] = 32'd0;
            completed_keep[(assembly_lane+1'b1)*4 +: 4] = 4'hf;
        end
    end

    assign pad_half_word = groups_per_pixel == 1;
    assign last_input = busy && total_groups_reg != 0
        && groups_received == total_groups_reg - 1'b1;
    assign push = busy && in_valid
        && ((pad_half_word && assembly_lane >= 2'd2)
            || (!pad_half_word && assembly_lane == 2'd3) || last_input);
    assign pop = m_axis_tvalid && m_axis_tready;
    assign push_ok = push && (fifo_count < FIFO_DEPTH || pop);

    assign m_axis_tvalid = fifo_count != 0;
    assign m_axis_tdata = fifo_data[fifo_head];
    assign m_axis_tkeep = fifo_keep[fifo_head];
    assign m_axis_tlast = fifo_last[fifo_head];

    assign output_capacity = busy
        && groups_received < total_groups_reg
        && fifo_count < FIFO_DEPTH - PIPELINE_RESERVE;

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_head <= '0;
            fifo_tail <= '0;
            fifo_count <= '0;
            assembly_data <= '0;
            assembly_keep <= '0;
            assembly_lane <= '0;
            total_groups_reg <= '0;
            groups_received <= '0;
            groups_written <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && busy)
                error <= 1'b1;

            if (start && !busy) begin
                if (total_groups == 0 || FIFO_DEPTH <= PIPELINE_RESERVE) begin
                    error <= 1'b1;
                end else begin
                    fifo_head <= '0;
                    fifo_tail <= '0;
                    fifo_count <= '0;
                    assembly_data <= '0;
                    assembly_keep <= '0;
                    assembly_lane <= '0;
                    total_groups_reg <= total_groups;
                    groups_received <= '0;
                    groups_written <= '0;
                    busy <= 1'b1;
                    error <= 1'b0;
                end
            end

            if (in_valid && !busy)
                error <= 1'b1;

            if (busy && in_valid) begin
                if (groups_received >= total_groups_reg) begin
                    error <= 1'b1;
                end else begin
                    groups_received <= groups_received + 1'b1;
                    if ((pad_half_word && assembly_lane >= 2'd2)
                            || (!pad_half_word && assembly_lane == 2'd3)
                            || last_input) begin
                        if (push_ok) begin
                            fifo_data[fifo_tail] <= completed_data;
                            fifo_keep[fifo_tail] <= completed_keep;
                            fifo_last[fifo_tail] <= last_input;
                            fifo_tail <= fifo_tail + 1'b1;
                        end else begin
                            error <= 1'b1;
                        end
                        assembly_data <= '0;
                        assembly_keep <= '0;
                        assembly_lane <= '0;
                    end else begin
                        assembly_data <= completed_data;
                        assembly_keep <= completed_keep;
                        assembly_lane <= assembly_lane + (pad_half_word ? 2'd2 : 2'd1);
                    end
                end
            end

            if (pop) begin
                fifo_head <= fifo_head + 1'b1;
                groups_written <= groups_written
                    + (fifo_keep[fifo_head][15:12] != 0 ? 4 :
                       fifo_keep[fifo_head][11:8] != 0 ? 3 :
                       fifo_keep[fifo_head][7:4] != 0 ? 2 : 1);
                if (fifo_last[fifo_head]) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end

            case ({push_ok, pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
