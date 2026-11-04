`timescale 1ns/1ps

module camus_pool_datamover_executor #(
    parameter integer MAX_WIDTH = 256,
    parameter integer MAX_GROUPS = 4
) (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base_bytes, input logic [31:0] output_base_bytes,
    input logic [8:0] width, input logic [8:0] height,
    input logic [2:0] groups, input logic [3:0] command_tag,
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
    output logic [31:0] input_stall_cycles,
    output logic [31:0] output_stall_cycles
);
    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_RUN} state_t;
    state_t state;
    logic [8:0] width_reg, height_reg;
    logic [2:0] groups_reg;
    logic [3:0] tag_reg;
    logic pool_start, pool_busy, pool_done, pool_error;
    logic split_valid, split_ready, split_last, split_error;
    logic [63:0] split_data;
    logic pool_valid, pool_ready, pool_last;
    logic [63:0] pool_data;
    logic pack_error;
    logic mm_cmd_seen, s2mm_cmd_seen, mm_status_seen, s2mm_status_seen;
    logic pool_done_seen;
    logic mm_cmd_fire, s2mm_cmd_fire, mm_status_fire, s2mm_status_fire;
    logic [31:0] input_bytes, output_bytes;
    logic [31:0] pixels_wide;

    assign busy = state != S_IDLE;
    assign pixels_wide = width_reg * height_reg;
    assign input_bytes = pixels_wide * groups_reg * 8;
    assign output_bytes = (pixels_wide >> 2) * groups_reg * 8;

    always_comb begin
        m_axis_mm2s_cmd_tdata = '0;
        m_axis_mm2s_cmd_tdata[67:64] = tag_reg;
        m_axis_mm2s_cmd_tdata[63:32] = input_base_bytes;
        m_axis_mm2s_cmd_tdata[31] = 1'b1;
        m_axis_mm2s_cmd_tdata[30] = 1'b1;
        m_axis_mm2s_cmd_tdata[23] = 1'b1;
        m_axis_mm2s_cmd_tdata[22:0] = input_bytes[22:0];
        m_axis_s2mm_cmd_tdata = '0;
        m_axis_s2mm_cmd_tdata[67:64] = tag_reg;
        m_axis_s2mm_cmd_tdata[63:32] = output_base_bytes;
        m_axis_s2mm_cmd_tdata[31] = 1'b1;
        m_axis_s2mm_cmd_tdata[30] = 1'b1;
        m_axis_s2mm_cmd_tdata[23] = 1'b1;
        m_axis_s2mm_cmd_tdata[22:0] = output_bytes[22:0];
    end

    assign m_axis_mm2s_cmd_tvalid = state == S_ISSUE && !mm_cmd_seen;
    assign m_axis_s2mm_cmd_tvalid = state == S_ISSUE && !s2mm_cmd_seen;
    assign mm_cmd_fire = m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready;
    assign s2mm_cmd_fire = m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready;
    assign s_axis_mm2s_sts_tready = state == S_RUN && !mm_status_seen;
    assign s_axis_s2mm_sts_tready = state == S_RUN && !s2mm_status_seen;
    assign mm_status_fire = s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready;
    assign s2mm_status_fire = s_axis_s2mm_sts_tvalid && s_axis_s2mm_sts_tready;

    camus_axis128_to_axis64 u_split (
        .clk(clk),.rst(rst),.s_valid(s_axis_mm2s_tvalid),
        .s_ready(s_axis_mm2s_tready),.s_data(s_axis_mm2s_tdata),
        .s_keep(s_axis_mm2s_tkeep),.s_last(s_axis_mm2s_tlast),
        .m_valid(split_valid),.m_ready(split_ready),.m_data(split_data),
        .m_last(split_last),.error(split_error));

    camus_pool2x2_axis #(.MAX_WIDTH(MAX_WIDTH),.MAX_GROUPS(MAX_GROUPS)) u_pool (
        .clk(clk),.rst(rst),.start(pool_start),.width(width_reg),.height(height_reg),
        .groups(groups_reg),.s_valid(split_valid),.s_ready(split_ready),
        .s_data(split_data),.s_last(split_last),.m_valid(pool_valid),
        .m_ready(pool_ready),.m_data(pool_data),.m_last(pool_last),
        .busy(pool_busy),.done(pool_done),.error(pool_error));

    camus_axis64_to_axis128 u_pack (
        .clk(clk),.rst(rst),.s_valid(pool_valid),.s_ready(pool_ready),
        .s_data(pool_data),.s_last(pool_last),.m_valid(m_axis_s2mm_tvalid),
        .m_ready(m_axis_s2mm_tready),.m_data(m_axis_s2mm_tdata),
        .m_keep(m_axis_s2mm_tkeep),.m_last(m_axis_s2mm_tlast),.error(pack_error));

    always_ff @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; width_reg<=0; height_reg<=0; groups_reg<=0; tag_reg<=0;
            pool_start<=0; mm_cmd_seen<=0; s2mm_cmd_seen<=0;
            mm_status_seen<=0; s2mm_status_seen<=0;
            pool_done_seen<=0;
            done<=0; error<=0; cycle_count<=0;
            input_stall_cycles<=0; output_stall_cycles<=0;
        end else begin
            pool_start<=0; done<=0;
            if (busy) begin
                cycle_count<=cycle_count+1'b1;
                if (s_axis_mm2s_tvalid && !s_axis_mm2s_tready)
                    input_stall_cycles<=input_stall_cycles+1'b1;
                if (m_axis_s2mm_tvalid && !m_axis_s2mm_tready)
                    output_stall_cycles<=output_stall_cycles+1'b1;
            end
            if (start && busy)
                error<=1'b1;
            if (split_error || pool_error || pack_error)
                error<=1'b1;

            case(state)
                S_IDLE: if(start) begin
                    if(width==0 || height==0 || width[0] || height[0]
                            || groups==0 || groups>MAX_GROUPS) begin
                        error<=1'b1;
                    end else begin
                        width_reg<=width; height_reg<=height; groups_reg<=groups;
                        tag_reg<=command_tag; mm_cmd_seen<=0; s2mm_cmd_seen<=0;
                        mm_status_seen<=0; s2mm_status_seen<=0;
                        pool_done_seen<=0;
                        cycle_count<=0; input_stall_cycles<=0; output_stall_cycles<=0;
                        error<=0; state<=S_ISSUE;
                    end
                end
                S_ISSUE: begin
                    if(mm_cmd_fire) mm_cmd_seen<=1'b1;
                    if(s2mm_cmd_fire) s2mm_cmd_seen<=1'b1;
                    if((mm_cmd_seen||mm_cmd_fire)&&(s2mm_cmd_seen||s2mm_cmd_fire)) begin
                        pool_start<=1'b1;
                        state<=S_RUN;
                    end
                end
                S_RUN: begin
                    if(pool_done)
                        pool_done_seen<=1'b1;
                    if(mm_status_fire) begin
                        mm_status_seen<=1'b1;
                        if(!s_axis_mm2s_sts_tdata[7] || |s_axis_mm2s_sts_tdata[6:4]
                                || s_axis_mm2s_sts_tdata[3:0]!=tag_reg)
                            error<=1'b1;
                    end
                    if(s2mm_status_fire) begin
                        s2mm_status_seen<=1'b1;
                        if(!s_axis_s2mm_sts_tdata[7] || |s_axis_s2mm_sts_tdata[6:4]
                                || s_axis_s2mm_sts_tdata[3:0]!=tag_reg)
                            error<=1'b1;
                    end
                    if((pool_done_seen||pool_done) && (mm_status_seen||mm_status_fire)
                            && (s2mm_status_seen||s2mm_status_fire)) begin
                        done<=1'b1; state<=S_IDLE;
                    end
                    if(watchdog_limit!=0 && cycle_count>=watchdog_limit) begin
                        error<=1'b1; done<=1'b1; state<=S_IDLE;
                    end
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
