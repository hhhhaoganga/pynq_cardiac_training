`timescale 1ns/1ps

// Streams padded SIMD8 head logits from DDR, performs signed INT8 Argmax,
// and writes one packed UINT8 class id per pixel to the mask buffer.
module camus_argmax_datamover_executor (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base_bytes, input logic [31:0] mask_base_bytes,
    input logic [8:0] width, input logic [8:0] height,
    input logic [3:0] command_tag, input logic [31:0] watchdog_limit,

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
    logic [31:0] pixels_reg;
    logic [3:0] tag_reg;
    logic mm_cmd_seen, s2mm_cmd_seen, mm_status_seen, s2mm_status_seen;
    logic output_done_seen;
    logic mm_cmd_fire, s2mm_cmd_fire, mm_status_fire, s2mm_status_fire;
    logic split_valid, split_ready, split_last, split_error;
    logic [63:0] split_data;
    logic arg_valid, arg_ready, arg_last;
    logic [7:0] arg_class;

    assign busy = state != S_IDLE;

    always_comb begin
        m_axis_mm2s_cmd_tdata = '0;
        m_axis_mm2s_cmd_tdata[67:64] = tag_reg;
        m_axis_mm2s_cmd_tdata[63:32] = input_base_bytes;
        m_axis_mm2s_cmd_tdata[31] = 1'b1;
        m_axis_mm2s_cmd_tdata[30] = 1'b1;
        m_axis_mm2s_cmd_tdata[23] = 1'b1;
        m_axis_mm2s_cmd_tdata[22:0] = pixels_reg << 3;
        m_axis_s2mm_cmd_tdata = '0;
        m_axis_s2mm_cmd_tdata[67:64] = tag_reg;
        m_axis_s2mm_cmd_tdata[63:32] = mask_base_bytes;
        m_axis_s2mm_cmd_tdata[31] = 1'b1;
        m_axis_s2mm_cmd_tdata[30] = 1'b1;
        m_axis_s2mm_cmd_tdata[23] = 1'b1;
        m_axis_s2mm_cmd_tdata[22:0] = pixels_reg[22:0];
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
        .clk,.rst,.s_valid(s_axis_mm2s_tvalid),.s_ready(s_axis_mm2s_tready),
        .s_data(s_axis_mm2s_tdata),.s_keep(s_axis_mm2s_tkeep),
        .s_last(s_axis_mm2s_tlast),.m_valid(split_valid),.m_ready(split_ready),
        .m_data(split_data),.m_last(split_last),.error(split_error));

    camus_argmax4_axis u_argmax (
        .clk,.rst,.s_valid(split_valid),.s_ready(split_ready),
        .s_logits(split_data[31:0]),.s_last(split_last),
        .m_valid(arg_valid),.m_ready(arg_ready),.m_class(arg_class),
        .m_last(arg_last));

    camus_mask16_axis_packer u_mask_pack (
        .clk,.rst,.s_valid(arg_valid),.s_ready(arg_ready),.s_class(arg_class),
        .s_last(arg_last),.m_valid(m_axis_s2mm_tvalid),
        .m_ready(m_axis_s2mm_tready),.m_data(m_axis_s2mm_tdata),
        .m_keep(m_axis_s2mm_tkeep),.m_last(m_axis_s2mm_tlast));

    always_ff @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; pixels_reg<=0; tag_reg<=0;
            mm_cmd_seen<=0; s2mm_cmd_seen<=0;
            mm_status_seen<=0; s2mm_status_seen<=0; output_done_seen<=0;
            done<=0; error<=0; cycle_count<=0;
            input_stall_cycles<=0; output_stall_cycles<=0;
        end else begin
            done<=0;
            if (busy) begin
                cycle_count<=cycle_count+1'b1;
                if(s_axis_mm2s_tvalid&&!s_axis_mm2s_tready)
                    input_stall_cycles<=input_stall_cycles+1'b1;
                if(m_axis_s2mm_tvalid&&!m_axis_s2mm_tready)
                    output_stall_cycles<=output_stall_cycles+1'b1;
            end
            if(start&&busy) error<=1'b1;
            if(split_error) error<=1'b1;
            if(m_axis_s2mm_tvalid&&m_axis_s2mm_tready&&m_axis_s2mm_tlast)
                output_done_seen<=1'b1;

            case(state)
                S_IDLE: if(start) begin
                    if(width==0||height==0) begin
                        error<=1'b1; done<=1'b1;
                    end else begin
                        pixels_reg<=width*height; tag_reg<=command_tag;
                        mm_cmd_seen<=0; s2mm_cmd_seen<=0;
                        mm_status_seen<=0; s2mm_status_seen<=0;
                        output_done_seen<=0; cycle_count<=0;
                        input_stall_cycles<=0; output_stall_cycles<=0;
                        error<=0; state<=S_ISSUE;
                    end
                end
                S_ISSUE: begin
                    if(mm_cmd_fire) mm_cmd_seen<=1'b1;
                    if(s2mm_cmd_fire) s2mm_cmd_seen<=1'b1;
                    if((mm_cmd_seen||mm_cmd_fire)&&(s2mm_cmd_seen||s2mm_cmd_fire))
                        state<=S_RUN;
                end
                S_RUN: begin
                    if(mm_status_fire) begin
                        mm_status_seen<=1'b1;
                        if(!s_axis_mm2s_sts_tdata[7]|| |s_axis_mm2s_sts_tdata[6:4]
                                ||s_axis_mm2s_sts_tdata[3:0]!=tag_reg)
                            error<=1'b1;
                    end
                    if(s2mm_status_fire) begin
                        s2mm_status_seen<=1'b1;
                        if(!s_axis_s2mm_sts_tdata[7]|| |s_axis_s2mm_sts_tdata[6:4]
                                ||s_axis_s2mm_sts_tdata[3:0]!=tag_reg)
                            error<=1'b1;
                    end
                    if((output_done_seen
                            ||m_axis_s2mm_tvalid&&m_axis_s2mm_tready&&m_axis_s2mm_tlast)
                            &&(mm_status_seen||mm_status_fire)
                            &&(s2mm_status_seen||s2mm_status_fire)) begin
                        done<=1'b1; state<=S_IDLE;
                    end
                    if(watchdog_limit!=0&&cycle_count>=watchdog_limit) begin
                        error<=1'b1; done<=1'b1; state<=S_IDLE;
                    end
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
