`timescale 1ns/1ps

// Three-pass DDR wrapper around camus_lcc_core.
// Pass 1: UINT8 mask -> packed {class,label} words in scratch DDR.
// Pass 2: read labels to accumulate root areas.
// Pass 3: read labels and overwrite the original mask with largest components.
module camus_lcc_datamover_executor #(
    parameter integer MAX_LABELS = 512
) (
    input logic clk,input logic rst,input logic start,
    input logic [31:0] mask_base_bytes,input logic [31:0] label_base_bytes,
    input logic [8:0] width,input logic [8:0] height,
    input logic [3:0] command_tag,input logic [31:0] watchdog_limit,

    output logic m_axis_mm2s_cmd_tvalid,input logic m_axis_mm2s_cmd_tready,
    output logic [71:0] m_axis_mm2s_cmd_tdata,
    input logic s_axis_mm2s_sts_tvalid,output logic s_axis_mm2s_sts_tready,
    input logic [7:0] s_axis_mm2s_sts_tdata,
    input logic s_axis_mm2s_tvalid,output logic s_axis_mm2s_tready,
    input logic [127:0] s_axis_mm2s_tdata,input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tlast,

    output logic m_axis_s2mm_cmd_tvalid,input logic m_axis_s2mm_cmd_tready,
    output logic [71:0] m_axis_s2mm_cmd_tdata,
    input logic s_axis_s2mm_sts_tvalid,output logic s_axis_s2mm_sts_tready,
    input logic [7:0] s_axis_s2mm_sts_tdata,
    output logic m_axis_s2mm_tvalid,input logic m_axis_s2mm_tready,
    output logic [127:0] m_axis_s2mm_tdata,output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tlast,

    output logic busy,output logic done,output logic error,output logic overflow,
    output logic [63:0] cycle_count,output logic [15:0] labels_used,
    output logic [4:0] debug_wait,
    output logic [50:0] area_counts
);
    typedef enum logic [3:0] {
        S_IDLE,S_PASS1_ISSUE,S_PASS1_RUN,S_WAIT_AREA,
        S_PASS2_ISSUE,S_PASS2_RUN,S_WAIT_FILTER,
        S_PASS3_ISSUE,S_PASS3_RUN,S_FINISH
    } state_t;
    state_t state;
    logic [8:0] width_reg,height_reg;
    logic [31:0] pixels,mask_bytes,label_bytes;
    logic [3:0] tag_reg,active_tag;
    logic core_start,core_busy,core_done,core_error,core_overflow;
    logic core_area_phase,core_filter_phase;
    logic [$clog2(MAX_LABELS):0] core_labels_used;
    logic [63:0] core_cycles;
    logic mm_cmd_seen,s2_cmd_seen,mm_status_seen,s2_status_seen,stream_done_seen;
    logic core_done_seen;
    logic [10:0] pass3_drain_count;
    logic mm_cmd_fire,s2_cmd_fire,mm_status_fire,s2_status_fire;
    logic phase_has_write;

    logic raw_valid,raw_ready,raw_last,raw_error;
    logic [7:0] raw_data;
    logic label_read_valid,label_read_ready,label_read_last,label_read_error;
    logic [15:0] label_read_data;
    logic core_label_valid,core_label_ready;
    logic [15:0] core_label_data;
    logic label_pack_valid,label_pack_ready,label_pack_last,label_pack_error;
    logic [127:0] label_pack_data;
    logic [15:0] label_pack_keep;
    logic core_mask_valid,core_mask_ready;
    logic [7:0] core_mask_data;
    logic mask_pack_valid,mask_pack_ready,mask_pack_last;
    logic [127:0] mask_pack_data;
    logic [15:0] mask_pack_keep;
    logic [31:0] label_out_count,mask_out_count;
    logic label_core_last,mask_core_last;
    logic raw_ready_core,label_read_ready_core;
    logic area_ready_core,filter_ready_core;

    assign busy=state!=S_IDLE;
    assign debug_wait={core_done_seen,mm_status_seen,s2_status_seen,
        stream_done_seen,core_busy};
    assign pixels=width_reg*height_reg;
    assign mask_bytes=pixels;
    assign label_bytes=pixels<<1;
    assign phase_has_write=state==S_PASS1_ISSUE||state==S_PASS1_RUN
        ||state==S_PASS3_ISSUE||state==S_PASS3_RUN;
    assign active_tag=state==S_PASS1_ISSUE||state==S_PASS1_RUN ? tag_reg
        : state==S_PASS2_ISSUE||state==S_PASS2_RUN ? tag_reg+1'b1
        : tag_reg+2'd2;

    always_comb begin
        m_axis_mm2s_cmd_tdata='0;
        m_axis_mm2s_cmd_tdata[67:64]=active_tag;
        m_axis_mm2s_cmd_tdata[63:32]=state==S_PASS1_ISSUE
            ?mask_base_bytes:label_base_bytes;
        m_axis_mm2s_cmd_tdata[31]=1'b1;
        m_axis_mm2s_cmd_tdata[30]=1'b1;
        m_axis_mm2s_cmd_tdata[23]=1'b1;
        m_axis_mm2s_cmd_tdata[22:0]=state==S_PASS1_ISSUE
            ?mask_bytes[22:0]:label_bytes[22:0];

        m_axis_s2mm_cmd_tdata='0;
        m_axis_s2mm_cmd_tdata[67:64]=active_tag;
        m_axis_s2mm_cmd_tdata[63:32]=state==S_PASS1_ISSUE
            ?label_base_bytes:mask_base_bytes;
        m_axis_s2mm_cmd_tdata[31]=1'b1;
        m_axis_s2mm_cmd_tdata[30]=1'b1;
        m_axis_s2mm_cmd_tdata[23]=1'b1;
        m_axis_s2mm_cmd_tdata[22:0]=state==S_PASS1_ISSUE
            ?label_bytes[22:0]:mask_bytes[22:0];
    end

    assign m_axis_mm2s_cmd_tvalid=(state==S_PASS1_ISSUE||state==S_PASS2_ISSUE
        ||state==S_PASS3_ISSUE)&&!mm_cmd_seen;
    assign m_axis_s2mm_cmd_tvalid=(state==S_PASS1_ISSUE||state==S_PASS3_ISSUE)
        &&!s2_cmd_seen;
    assign mm_cmd_fire=m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready;
    assign s2_cmd_fire=m_axis_s2mm_cmd_tvalid&&m_axis_s2mm_cmd_tready;
    assign s_axis_mm2s_sts_tready=(state==S_PASS1_RUN||state==S_PASS2_RUN
        ||state==S_PASS3_RUN)&&!mm_status_seen;
    assign s_axis_s2mm_sts_tready=(state==S_PASS1_RUN||state==S_PASS3_RUN)
        &&!s2_status_seen;
    assign mm_status_fire=s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready;
    assign s2_status_fire=s_axis_s2mm_sts_tvalid&&s_axis_s2mm_sts_tready;

    camus_axis128_to_u8 u_raw_reader(
        .clk,.rst,.s_valid(s_axis_mm2s_tvalid&&state==S_PASS1_RUN),
        .s_ready(raw_ready),.s_data(s_axis_mm2s_tdata),.s_keep(s_axis_mm2s_tkeep),
        .s_last(s_axis_mm2s_tlast),.m_valid(raw_valid),
        .m_ready(core_busy&&raw_ready_core),.m_data(raw_data),.m_last(raw_last),
        .error(raw_error));
    camus_axis128_to_u16 u_label_reader(
        .clk,.rst,.s_valid(s_axis_mm2s_tvalid&&(state==S_PASS2_RUN||state==S_PASS3_RUN)),
        .s_ready(label_read_ready),.s_data(s_axis_mm2s_tdata),
        .s_keep(s_axis_mm2s_tkeep),.s_last(s_axis_mm2s_tlast),
        .m_valid(label_read_valid),.m_ready(label_read_ready_core),
        .m_data(label_read_data),.m_last(label_read_last),.error(label_read_error));
    assign s_axis_mm2s_tready=state==S_PASS1_RUN?raw_ready
        :(state==S_PASS2_RUN||state==S_PASS3_RUN)?label_read_ready:1'b0;

    camus_u16_axis128_packer u_label_packer(
        .clk,.rst,.s_valid(core_label_valid),.s_ready(core_label_ready),
        .s_data(core_label_data),.s_last(label_core_last),
        .m_valid(label_pack_valid),.m_ready(label_pack_ready),
        .m_data(label_pack_data),.m_keep(label_pack_keep),
        .m_last(label_pack_last),.error(label_pack_error));

    camus_mask16_axis_packer u_mask_packer(
        .clk,.rst,.s_valid(core_mask_valid),.s_ready(core_mask_ready),
        .s_class(core_mask_data),.s_last(mask_core_last),
        .m_valid(mask_pack_valid),.m_ready(mask_pack_ready),
        .m_data(mask_pack_data),.m_keep(mask_pack_keep),.m_last(mask_pack_last));

    assign label_pack_ready=state==S_PASS1_RUN&&m_axis_s2mm_tready;
    assign mask_pack_ready=state==S_PASS3_RUN&&m_axis_s2mm_tready;
    assign m_axis_s2mm_tvalid=state==S_PASS1_RUN?label_pack_valid
        :state==S_PASS3_RUN?mask_pack_valid:1'b0;
    assign m_axis_s2mm_tdata=state==S_PASS1_RUN?label_pack_data:mask_pack_data;
    assign m_axis_s2mm_tkeep=state==S_PASS1_RUN?label_pack_keep:mask_pack_keep;
    assign m_axis_s2mm_tlast=state==S_PASS1_RUN?label_pack_last:mask_pack_last;
    assign label_core_last=label_out_count==pixels-1'b1;
    assign mask_core_last=mask_out_count==pixels-1'b1;

    camus_lcc_core #(.MAX_LABELS(MAX_LABELS)) u_core(
        .clk,.rst,.start(core_start),.width(width_reg),.height(height_reg),
        .s_mask_valid(raw_valid&&state==S_PASS1_RUN),.s_mask_ready(raw_ready_core),
        .s_mask_class(raw_data),.m_label_valid(core_label_valid),
        .m_label_ready(core_label_ready),.m_label(core_label_data),
        .area_phase(core_area_phase),
        .s_area_valid(label_read_valid&&state==S_PASS2_RUN),
        .s_area_ready(area_ready_core),.s_area_label(label_read_data),
        .filter_phase(core_filter_phase),
        .s_filter_valid(label_read_valid&&state==S_PASS3_RUN),
        .s_filter_ready(filter_ready_core),.s_filter_label(label_read_data),
        .m_mask_valid(core_mask_valid),.m_mask_ready(core_mask_ready),
        .m_mask_class(core_mask_data),.busy(core_busy),.done(core_done),
        .error(core_error),.overflow(core_overflow),.labels_used(core_labels_used),
        .cycle_count(core_cycles));
    assign label_read_ready_core=state==S_PASS2_RUN?area_ready_core
        :state==S_PASS3_RUN?filter_ready_core:1'b0;

    // Count accepted final-mask pixels only, including under output backpressure.
    // Seventeen bits represent a full 256x256 foreground frame without wrapping.
    always_ff @(posedge clk) begin
        if (rst || (start && !busy))
            area_counts <= '0;
        else if (core_mask_valid && core_mask_ready) begin
            case (core_mask_data)
                8'd1: area_counts[16:0] <= area_counts[16:0] + 1'b1;
                8'd2: area_counts[33:17] <= area_counts[33:17] + 1'b1;
                8'd3: area_counts[50:34] <= area_counts[50:34] + 1'b1;
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=S_IDLE;width_reg<=0;height_reg<=0;tag_reg<=0;core_start<=0;
            mm_cmd_seen<=0;s2_cmd_seen<=0;mm_status_seen<=0;s2_status_seen<=0;
            stream_done_seen<=0;core_done_seen<=0;
            pass3_drain_count<=0;
            label_out_count<=0;mask_out_count<=0;
            done<=0;error<=0;overflow<=0;cycle_count<=0;labels_used<=0;
        end else begin
            core_start<=0;done<=0;
            if(busy) cycle_count<=cycle_count+1'b1;
            if(start&&busy) error<=1'b1;
            if(raw_error||label_read_error||label_pack_error||core_error) error<=1'b1;
            if(core_overflow) overflow<=1'b1;
            if(core_done) core_done_seen<=1'b1;
            if(core_label_valid&&core_label_ready) label_out_count<=label_out_count+1'b1;
            if(core_mask_valid&&core_mask_ready) mask_out_count<=mask_out_count+1'b1;
            if(m_axis_s2mm_tvalid&&m_axis_s2mm_tready&&m_axis_s2mm_tlast)
                stream_done_seen<=1'b1;
            if(mm_status_fire) begin
                mm_status_seen<=1'b1;
                if(!s_axis_mm2s_sts_tdata[7]|| |s_axis_mm2s_sts_tdata[6:4]
                        ||s_axis_mm2s_sts_tdata[3:0]!=active_tag) error<=1'b1;
            end
            if(s2_status_fire) begin
                s2_status_seen<=1'b1;
                if(!s_axis_s2mm_sts_tdata[7]|| |s_axis_s2mm_sts_tdata[6:4]
                        ||s_axis_s2mm_sts_tdata[3:0]!=active_tag) error<=1'b1;
            end

            case(state)
                S_IDLE: if(start) begin
                    if(width==0||height==0) begin error<=1;done<=1;end
                    else begin
                        width_reg<=width;height_reg<=height;tag_reg<=command_tag;
                        core_start<=1;mm_cmd_seen<=0;s2_cmd_seen<=0;
                        mm_status_seen<=0;s2_status_seen<=0;stream_done_seen<=0;
                        core_done_seen<=0;
                        pass3_drain_count<=0;
                        label_out_count<=0;mask_out_count<=0;cycle_count<=0;
                        error<=0;overflow<=0;labels_used<=0;state<=S_PASS1_ISSUE;
                    end
                end
                S_PASS1_ISSUE: begin
                    if(mm_cmd_fire) mm_cmd_seen<=1;
                    if(s2_cmd_fire) s2_cmd_seen<=1;
                    if((mm_cmd_seen||mm_cmd_fire)&&(s2_cmd_seen||s2_cmd_fire)) state<=S_PASS1_RUN;
                end
                S_PASS1_RUN: if((mm_status_seen||mm_status_fire)
                        &&(s2_status_seen||s2_status_fire)
                        &&(stream_done_seen||(m_axis_s2mm_tvalid&&m_axis_s2mm_tready&&m_axis_s2mm_tlast))) begin
                    state<=S_WAIT_AREA;
                end
                S_WAIT_AREA: if(core_area_phase) begin
                    mm_cmd_seen<=0;mm_status_seen<=0;stream_done_seen<=0;
                    state<=S_PASS2_ISSUE;
                end
                S_PASS2_ISSUE: begin
                    if(mm_cmd_fire) mm_cmd_seen<=1;
                    if(mm_cmd_seen||mm_cmd_fire) state<=S_PASS2_RUN;
                end
                S_PASS2_RUN: if((mm_status_seen||mm_status_fire)&&!core_area_phase)
                    state<=S_WAIT_FILTER;
                S_WAIT_FILTER: if(core_filter_phase) begin
                    mm_cmd_seen<=0;s2_cmd_seen<=0;mm_status_seen<=0;s2_status_seen<=0;
                    stream_done_seen<=0;pass3_drain_count<=0;state<=S_PASS3_ISSUE;
                end
                S_PASS3_ISSUE: begin
                    if(mm_cmd_fire) mm_cmd_seen<=1;
                    if(s2_cmd_fire) s2_cmd_seen<=1;
                    if((mm_cmd_seen||mm_cmd_fire)&&(s2_cmd_seen||s2_cmd_fire)) state<=S_PASS3_RUN;
                end
                S_PASS3_RUN: begin
                    // Some AXI DataMover builds do not return the final S2MM
                    // status even though the complete TLAST-terminated burst
                    // has been accepted and committed. The top-level DMA
                    // error pins remain monitored. Drain the write path for
                    // 1024 clocks, then allow completion using the observable
                    // core-idle and stream-last conditions.
                    if(stream_done_seen
                            ||(m_axis_s2mm_tvalid&&m_axis_s2mm_tready
                                &&m_axis_s2mm_tlast)) begin
                        if(pass3_drain_count!=11'd1024)
                            pass3_drain_count<=pass3_drain_count+1'b1;
                    end
                    if((core_done_seen||core_done||!core_busy)
                            &&(mm_status_seen||mm_status_fire)
                            &&(s2_status_seen||s2_status_fire
                                ||pass3_drain_count==11'd1024)
                            &&(stream_done_seen
                                ||(m_axis_s2mm_tvalid&&m_axis_s2mm_tready
                                    &&m_axis_s2mm_tlast))) begin
                        labels_used<=core_labels_used;state<=S_FINISH;
                    end
                end
                S_FINISH: begin done<=1;state<=S_IDLE;end
                default: state<=S_IDLE;
            endcase
            if(watchdog_limit!=0&&busy&&cycle_count>=watchdog_limit) begin
                error<=1;done<=1;state<=S_IDLE;
            end
        end
    end
endmodule
