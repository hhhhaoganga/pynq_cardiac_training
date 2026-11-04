`timescale 1ns/1ps

// Encoder phase: eight convolution jobs and three pooling jobs.  The final
// convolution writes directly into the shared history bridge instead of DDR.
module camus_encoder_phase_executor (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base, input logic [31:0] mask_base,
    input logic [31:0] skip_base, input logic [31:0] scratch_base,
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

    output logic hist_cmd_valid,
    input logic hist_cmd_ready,
    output logic [71:0] hist_cmd_data,
    input logic hist_status_valid,
    output logic hist_status_ready,
    input logic [7:0] hist_status_data,
    output logic hist_data_valid,
    input logic hist_data_ready,
    output logic [127:0] hist_data,
    output logic [15:0] hist_keep,
    output logic hist_last,

    output logic busy, output logic done, output logic error,
    output logic [63:0] cycle_count,
    output logic [4:0] current_op
);
    localparam logic [2:0] OP_CONV=3'd0,OP_POOL=3'd1;
    logic op_start,op_done,op_error;
    logic [2:0] op_kind;
    logic [4:0] op_index,layer_index;
    logic [31:0] source_address,source_b_address,dest_address;
    logic [8:0] height,width,tile_rows;
    logic [3:0] input_groups,output_groups,stored_output_groups;
    logic kernel_3x3,relu_enable;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [19:0] input_row_words;
    logic [31:0] input_row_bytes,input_tile_stride_bytes,output_row_bytes;
    logic conv_selected,pool_selected,conv_to_history;
    logic hist_cmd_raw_valid,hist_cmd_raw_ready;
    logic [71:0] hist_cmd_raw_data;

    logic conv_mm_cmd_valid,conv_mm_cmd_ready;
    logic [71:0] conv_mm_cmd_data;
    logic conv_mm_sts_valid,conv_mm_sts_ready;
    logic [7:0] conv_mm_sts_data;
    logic conv_mm_valid,conv_mm_ready,conv_mm_last;
    logic [127:0] conv_mm_data;
    logic [15:0] conv_mm_keep;
    logic conv_s2_cmd_valid,conv_s2_cmd_ready;
    logic [71:0] conv_s2_cmd_data;
    logic conv_s2_sts_valid,conv_s2_sts_ready;
    logic [7:0] conv_s2_sts_data;
    logic conv_s2_valid,conv_s2_ready,conv_s2_last;
    logic [127:0] conv_s2_data;
    logic [15:0] conv_s2_keep;
    logic conv_busy,conv_done,conv_error;
    logic [31:0] conv_cycles,conv_load_wait,conv_compute;
    logic [31:0] conv_output_wait,conv_output_stall;
    logic [15:0] conv_strips;

    logic pool_mm_cmd_valid,pool_mm_cmd_ready;
    logic [71:0] pool_mm_cmd_data;
    logic pool_mm_sts_valid,pool_mm_sts_ready;
    logic [7:0] pool_mm_sts_data;
    logic pool_mm_valid,pool_mm_ready,pool_mm_last;
    logic [127:0] pool_mm_data;
    logic [15:0] pool_mm_keep;
    logic pool_s2_cmd_valid,pool_s2_cmd_ready;
    logic [71:0] pool_s2_cmd_data;
    logic pool_s2_sts_valid,pool_s2_sts_ready;
    logic [7:0] pool_s2_sts_data;
    logic pool_s2_valid,pool_s2_ready,pool_s2_last;
    logic [127:0] pool_s2_data;
    logic [15:0] pool_s2_keep;
    logic pool_busy,pool_done,pool_error;
    logic [63:0] pool_cycles;
    logic [31:0] pool_input_stall,pool_output_stall;

    assign current_op=op_index;
    assign conv_selected=op_kind==OP_CONV;
    assign pool_selected=op_kind==OP_POOL;
    assign conv_to_history=conv_selected&&op_index==5'd10;
    assign op_done=conv_selected?conv_done:pool_selected?pool_done:1'b0;
    assign op_error=conv_selected?conv_error:pool_selected?pool_error:1'b1;

    camus_phase_scheduler #(.FIRST_OP(0),.LAST_OP(10)) u_scheduler (
        .clk,.rst,.start,.op_done,.op_error,.input_base,.mask_base,.skip_base,
        .scratch_base,.op_start,.op_kind,.op_index,.layer_index,.source_address,
        .source_b_address,.dest_address,.height,.width,.tile_rows,.input_groups,
        .output_groups,.stored_output_groups,.kernel_3x3,.weight_base,
        .parameter_base,.tokens_per_output_group,.relu_enable,.input_row_words,
        .input_row_bytes,.input_tile_stride_bytes,.output_row_bytes,
        .busy,.done,.error,.cycle_count);

    camus_axis72_register_slice u_hist_cmd_slice (
        .clk,.rst,.s_valid(hist_cmd_raw_valid),.s_ready(hist_cmd_raw_ready),
        .s_data(hist_cmd_raw_data),.m_valid(hist_cmd_valid),
        .m_ready(hist_cmd_ready),.m_data(hist_cmd_data));

    camus_datamover_strip_executor u_conv (
        .clk,.rst,.start(op_start&&conv_selected),
        .input_base_bytes(source_address),.output_base_bytes(dest_address),
        .input_row_words,.input_row_bytes,.input_tile_stride_bytes,
        .output_row_bytes,.frame_height(height),.width,.tile_rows,.input_groups,
        .output_groups,.kernel_3x3,.weight_base,.parameter_base,
        .tokens_per_output_group,.relu_enable,.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(conv_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(conv_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(conv_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(conv_mm_sts_valid),
        .s_axis_mm2s_sts_tready(conv_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(conv_mm_sts_data),
        .s_axis_mm2s_tvalid(conv_mm_valid),.s_axis_mm2s_tready(conv_mm_ready),
        .s_axis_mm2s_tdata(conv_mm_data),.s_axis_mm2s_tkeep(conv_mm_keep),
        .s_axis_mm2s_tlast(conv_mm_last),
        .m_axis_s2mm_cmd_tvalid(conv_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(conv_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(conv_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(conv_s2_sts_valid),
        .s_axis_s2mm_sts_tready(conv_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(conv_s2_sts_data),
        .m_axis_s2mm_tvalid(conv_s2_valid),.m_axis_s2mm_tready(conv_s2_ready),
        .m_axis_s2mm_tdata(conv_s2_data),.m_axis_s2mm_tkeep(conv_s2_keep),
        .m_axis_s2mm_tlast(conv_s2_last),.busy(conv_busy),.done(conv_done),
        .error(conv_error),.cycle_count(conv_cycles),
        .load_wait_cycles(conv_load_wait),.compute_cycles(conv_compute),
        .output_wait_cycles(conv_output_wait),
        .output_stall_count(conv_output_stall),.strips_completed(conv_strips));

    camus_pool_datamover_executor u_pool (
        .clk,.rst,.start(op_start&&pool_selected),
        .input_base_bytes(source_address),.output_base_bytes(dest_address),
        .width,.height,.groups(stored_output_groups[2:0]),
        .command_tag(op_index[3:0]),.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(pool_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(pool_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(pool_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(pool_mm_sts_valid),
        .s_axis_mm2s_sts_tready(pool_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(pool_mm_sts_data),
        .s_axis_mm2s_tvalid(pool_mm_valid),.s_axis_mm2s_tready(pool_mm_ready),
        .s_axis_mm2s_tdata(pool_mm_data),.s_axis_mm2s_tkeep(pool_mm_keep),
        .s_axis_mm2s_tlast(pool_mm_last),
        .m_axis_s2mm_cmd_tvalid(pool_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(pool_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(pool_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(pool_s2_sts_valid),
        .s_axis_s2mm_sts_tready(pool_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(pool_s2_sts_data),
        .m_axis_s2mm_tvalid(pool_s2_valid),.m_axis_s2mm_tready(pool_s2_ready),
        .m_axis_s2mm_tdata(pool_s2_data),.m_axis_s2mm_tkeep(pool_s2_keep),
        .m_axis_s2mm_tlast(pool_s2_last),.busy(pool_busy),.done(pool_done),
        .error(pool_error),.cycle_count(pool_cycles),
        .input_stall_cycles(pool_input_stall),
        .output_stall_cycles(pool_output_stall));

    always_comb begin
        m_axis_mm2s_cmd_tvalid=0;m_axis_mm2s_cmd_tdata=0;
        s_axis_mm2s_sts_tready=0;s_axis_mm2s_tready=0;
        m_axis_s2mm_cmd_tvalid=0;m_axis_s2mm_cmd_tdata=0;
        s_axis_s2mm_sts_tready=0;m_axis_s2mm_tvalid=0;
        m_axis_s2mm_tdata=0;m_axis_s2mm_tkeep=0;m_axis_s2mm_tlast=0;
        hist_cmd_raw_valid=0;hist_cmd_raw_data=0;hist_status_ready=0;
        hist_data_valid=0;hist_data=0;hist_keep=0;hist_last=0;

        conv_mm_cmd_ready=0;conv_mm_sts_valid=0;conv_mm_sts_data=0;
        conv_mm_valid=0;conv_mm_data=0;conv_mm_keep=0;conv_mm_last=0;
        conv_s2_cmd_ready=0;conv_s2_sts_valid=0;conv_s2_sts_data=0;
        conv_s2_ready=0;
        pool_mm_cmd_ready=0;pool_mm_sts_valid=0;pool_mm_sts_data=0;
        pool_mm_valid=0;pool_mm_data=0;pool_mm_keep=0;pool_mm_last=0;
        pool_s2_cmd_ready=0;pool_s2_sts_valid=0;pool_s2_sts_data=0;
        pool_s2_ready=0;

        if(conv_selected) begin
            m_axis_mm2s_cmd_tvalid=conv_mm_cmd_valid;
            m_axis_mm2s_cmd_tdata=conv_mm_cmd_data;
            conv_mm_cmd_ready=m_axis_mm2s_cmd_tready;
            conv_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            conv_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=conv_mm_sts_ready;
            conv_mm_valid=s_axis_mm2s_tvalid;conv_mm_data=s_axis_mm2s_tdata;
            conv_mm_keep=s_axis_mm2s_tkeep;conv_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=conv_mm_ready;
            if(conv_to_history) begin
                hist_cmd_raw_valid=conv_s2_cmd_valid;
                hist_cmd_raw_data=conv_s2_cmd_data;
                conv_s2_cmd_ready=hist_cmd_raw_ready;
                conv_s2_sts_valid=hist_status_valid;
                conv_s2_sts_data=hist_status_data;
                hist_status_ready=conv_s2_sts_ready;
                hist_data_valid=conv_s2_valid;hist_data=conv_s2_data;
                hist_keep=conv_s2_keep;hist_last=conv_s2_last;
                conv_s2_ready=hist_data_ready;
            end else begin
                m_axis_s2mm_cmd_tvalid=conv_s2_cmd_valid;
                m_axis_s2mm_cmd_tdata=conv_s2_cmd_data;
                conv_s2_cmd_ready=m_axis_s2mm_cmd_tready;
                conv_s2_sts_valid=s_axis_s2mm_sts_tvalid;
                conv_s2_sts_data=s_axis_s2mm_sts_tdata;
                s_axis_s2mm_sts_tready=conv_s2_sts_ready;
                m_axis_s2mm_tvalid=conv_s2_valid;
                m_axis_s2mm_tdata=conv_s2_data;m_axis_s2mm_tkeep=conv_s2_keep;
                m_axis_s2mm_tlast=conv_s2_last;conv_s2_ready=m_axis_s2mm_tready;
            end
        end else if(pool_selected) begin
            m_axis_mm2s_cmd_tvalid=pool_mm_cmd_valid;
            m_axis_mm2s_cmd_tdata=pool_mm_cmd_data;
            pool_mm_cmd_ready=m_axis_mm2s_cmd_tready;
            pool_mm_sts_valid=s_axis_mm2s_sts_tvalid;
            pool_mm_sts_data=s_axis_mm2s_sts_tdata;
            s_axis_mm2s_sts_tready=pool_mm_sts_ready;
            pool_mm_valid=s_axis_mm2s_tvalid;pool_mm_data=s_axis_mm2s_tdata;
            pool_mm_keep=s_axis_mm2s_tkeep;pool_mm_last=s_axis_mm2s_tlast;
            s_axis_mm2s_tready=pool_mm_ready;
            m_axis_s2mm_cmd_tvalid=pool_s2_cmd_valid;
            m_axis_s2mm_cmd_tdata=pool_s2_cmd_data;
            pool_s2_cmd_ready=m_axis_s2mm_cmd_tready;
            pool_s2_sts_valid=s_axis_s2mm_sts_tvalid;
            pool_s2_sts_data=s_axis_s2mm_sts_tdata;
            s_axis_s2mm_sts_tready=pool_s2_sts_ready;
            m_axis_s2mm_tvalid=pool_s2_valid;m_axis_s2mm_tdata=pool_s2_data;
            m_axis_s2mm_tkeep=pool_s2_keep;m_axis_s2mm_tlast=pool_s2_last;
            pool_s2_ready=m_axis_s2mm_tready;
        end
    end
endmodule
