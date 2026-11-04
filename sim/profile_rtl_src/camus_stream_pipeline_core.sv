`timescale 1ns/1ps

// Continuous two-slot wrapper around compact input expansion and the complete
// encoder/decoder graph. The encoder DataMover is time-multiplexed between
// input expansion and encoder execution; the decoder owns a separate port.
module camus_stream_pipeline_core (
    input logic clk,input logic rst,input logic clear_history,
    input logic frame_valid,output logic frame_ready,
    input logic [31:0] frame_input_base,input logic [31:0] frame_mask_base,
    input logic [31:0] frame_id,
    input logic [31:0] slot0_padded_base,input logic [31:0] slot0_skip_base,
    input logic [31:0] slot0_scratch_base,
    input logic [31:0] slot1_padded_base,input logic [31:0] slot1_skip_base,
    input logic [31:0] slot1_scratch_base,
    input logic [31:0] watchdog_limit,
    input logic [31:0] post_base,

    output logic enc_mm2s_cmd_valid,input logic enc_mm2s_cmd_ready,
    output logic [71:0] enc_mm2s_cmd_data,
    input logic enc_mm2s_sts_valid,output logic enc_mm2s_sts_ready,
    input logic [7:0] enc_mm2s_sts_data,
    input logic enc_mm2s_valid,output logic enc_mm2s_ready,
    input logic [127:0] enc_mm2s_data,input logic [15:0] enc_mm2s_keep,
    input logic enc_mm2s_last,
    output logic enc_s2mm_cmd_valid,input logic enc_s2mm_cmd_ready,
    output logic [71:0] enc_s2mm_cmd_data,
    input logic enc_s2mm_sts_valid,output logic enc_s2mm_sts_ready,
    input logic [7:0] enc_s2mm_sts_data,
    output logic enc_s2mm_valid,input logic enc_s2mm_ready,
    output logic [127:0] enc_s2mm_data,output logic [15:0] enc_s2mm_keep,
    output logic enc_s2mm_last,

    output logic dec_mm2s_cmd_valid,input logic dec_mm2s_cmd_ready,
    output logic [71:0] dec_mm2s_cmd_data,
    input logic dec_mm2s_sts_valid,output logic dec_mm2s_sts_ready,
    input logic [7:0] dec_mm2s_sts_data,
    input logic dec_mm2s_valid,output logic dec_mm2s_ready,
    input logic [127:0] dec_mm2s_data,input logic [15:0] dec_mm2s_keep,
    input logic dec_mm2s_last,
    output logic dec_s2mm_cmd_valid,input logic dec_s2mm_cmd_ready,
    output logic [71:0] dec_s2mm_cmd_data,
    input logic dec_s2mm_sts_valid,output logic dec_s2mm_sts_ready,
    input logic [7:0] dec_s2mm_sts_data,
    output logic dec_s2mm_valid,input logic dec_s2mm_ready,
    output logic [127:0] dec_s2mm_data,output logic [15:0] dec_s2mm_keep,
    output logic dec_s2mm_last,

    output logic post_mm2s_cmd_valid,input logic post_mm2s_cmd_ready,
    output logic [71:0] post_mm2s_cmd_data,
    input logic post_mm2s_sts_valid,output logic post_mm2s_sts_ready,
    input logic [7:0] post_mm2s_sts_data,
    input logic post_mm2s_valid,output logic post_mm2s_ready,
    input logic [127:0] post_mm2s_data,input logic [15:0] post_mm2s_keep,
    input logic post_mm2s_last,
    output logic post_s2mm_cmd_valid,input logic post_s2mm_cmd_ready,
    output logic [71:0] post_s2mm_cmd_data,
    input logic post_s2mm_sts_valid,output logic post_s2mm_sts_ready,
    input logic [7:0] post_s2mm_sts_data,
    output logic post_s2mm_valid,input logic post_s2mm_ready,
    output logic [127:0] post_s2mm_data,output logic [15:0] post_s2mm_keep,
    output logic post_s2mm_last,

    output logic result_valid,input logic result_ready,
    output logic [31:0] result_mask_base,output logic [31:0] result_frame_id,
    output logic busy,output logic error,
    output logic [63:0] frames_accepted,output logic [63:0] frames_completed,
    output logic [63:0] pack_cycle_count,output logic [63:0] enc_cycle_count,
    output logic [63:0] dec_cycle_count,
    output logic [63:0] post_cycle_count,
    output logic [63:0] result_pack_cycles,result_enc_cycles,
    output logic [63:0] result_dec_cycles,result_post_cycles,
    output logic [4:0] enc_current_op,output logic [4:0] dec_current_op,
    output logic [1:0] history_count,
    output logic [50:0] area_counts,
    input logic profile_rearm,
    input logic [7:0] profile_read_index,
    output logic [31:0] profile_read_data
);
    logic pack_start,pack_done,pack_error,pack_busy;
    logic [31:0] pack_input_base,pack_output_base;
    logic [31:0] pack_input_stall,pack_output_stall;
    logic core_enc_start,core_dec_start;
    logic [31:0] core_enc_input_base,core_enc_skip_base,core_enc_scratch_base;
    logic [31:0] core_dec_mask_base,core_dec_skip_base,core_dec_scratch_base;
    logic core_enc_busy,core_enc_done,core_enc_error;
    logic core_dec_busy,core_dec_done,core_dec_error;
    logic post_start,post_busy,post_done,post_error;
    logic [31:0] post_logits_base,post_mask_base;
    logic [50:0] post_areas;
    logic [4:0] post_current_op;
    logic history_busy,history_error,controller_busy,controller_error;
    logic encoder_dma_owner_pack;

    logic pack_mm_cmd_valid,pack_mm_cmd_ready;
    logic [71:0] pack_mm_cmd_data;
    logic pack_mm_sts_valid,pack_mm_sts_ready;
    logic [7:0] pack_mm_sts_data;
    logic pack_mm_valid,pack_mm_ready,pack_mm_last;
    logic [127:0] pack_mm_data;
    logic [15:0] pack_mm_keep;
    logic pack_s2_cmd_valid,pack_s2_cmd_ready;
    logic [71:0] pack_s2_cmd_data;
    logic pack_s2_sts_valid,pack_s2_sts_ready;
    logic [7:0] pack_s2_sts_data;
    logic pack_s2_valid,pack_s2_ready,pack_s2_last;
    logic [127:0] pack_s2_data;
    logic [15:0] pack_s2_keep;

    logic core_mm_cmd_valid,core_mm_cmd_ready;
    logic [71:0] core_mm_cmd_data;
    logic core_mm_sts_valid,core_mm_sts_ready;
    logic [7:0] core_mm_sts_data;
    logic core_mm_valid,core_mm_ready,core_mm_last;
    logic [127:0] core_mm_data;
    logic [15:0] core_mm_keep;
    logic core_s2_cmd_valid,core_s2_cmd_ready;
    logic [71:0] core_s2_cmd_data;
    logic core_s2_sts_valid,core_s2_sts_ready;
    logic [7:0] core_s2_sts_data;
    logic core_s2_valid,core_s2_ready,core_s2_last;
    logic [127:0] core_s2_data;
    logic [15:0] core_s2_keep;

    assign busy=controller_busy;
    assign error=controller_error||pack_error||core_enc_error||core_dec_error
        ||history_error||post_error;

    camus_three_stage_controller u_controller (
        .clk,.rst,.frame_valid,.frame_ready,.frame_input_base,.frame_mask_base,
        .frame_id,.slot0_padded_base,.slot0_skip_base,.slot0_scratch_base,
        .slot1_padded_base,.slot1_skip_base,.slot1_scratch_base,
        .post_base,.post_start,.post_logits_base,.post_mask_base,
        .post_done,.post_error,.pack_cycles(pack_cycle_count),
        .enc_cycles(enc_cycle_count),.dec_cycles(dec_cycle_count),
        .post_cycles(post_cycle_count),.post_areas,
        .result_pack_cycles,.result_enc_cycles,.result_dec_cycles,.result_post_cycles,
        .result_areas(area_counts),
        .pack_start,.pack_input_base,.pack_output_base,.pack_done,
        .pack_error,.enc_start(core_enc_start),.enc_input_base(core_enc_input_base),
        .enc_skip_base(core_enc_skip_base),.enc_scratch_base(core_enc_scratch_base),
        .enc_done(core_enc_done),.enc_error(core_enc_error),
        .dec_start(core_dec_start),.dec_mask_base(core_dec_mask_base),
        .dec_skip_base(core_dec_skip_base),.dec_scratch_base(core_dec_scratch_base),
        .dec_done(core_dec_done),.dec_error(core_dec_error),
        .result_valid,.result_ready,.result_mask_base,.result_frame_id,
        .encoder_dma_owner_pack,.busy(controller_busy),.error(controller_error),
        .frames_accepted,.frames_completed);

    camus_compact_input_datamover_executor u_input_pack (
        .clk,.rst,.start(pack_start),.input_base_bytes(pack_input_base),
        .output_base_bytes(pack_output_base),.width(9'd256),.height(9'd256),
        .command_tag(4'hf),.watchdog_limit,
        .m_axis_mm2s_cmd_tvalid(pack_mm_cmd_valid),
        .m_axis_mm2s_cmd_tready(pack_mm_cmd_ready),
        .m_axis_mm2s_cmd_tdata(pack_mm_cmd_data),
        .s_axis_mm2s_sts_tvalid(pack_mm_sts_valid),
        .s_axis_mm2s_sts_tready(pack_mm_sts_ready),
        .s_axis_mm2s_sts_tdata(pack_mm_sts_data),
        .s_axis_mm2s_tvalid(pack_mm_valid),.s_axis_mm2s_tready(pack_mm_ready),
        .s_axis_mm2s_tdata(pack_mm_data),.s_axis_mm2s_tkeep(pack_mm_keep),
        .s_axis_mm2s_tlast(pack_mm_last),
        .m_axis_s2mm_cmd_tvalid(pack_s2_cmd_valid),
        .m_axis_s2mm_cmd_tready(pack_s2_cmd_ready),
        .m_axis_s2mm_cmd_tdata(pack_s2_cmd_data),
        .s_axis_s2mm_sts_tvalid(pack_s2_sts_valid),
        .s_axis_s2mm_sts_tready(pack_s2_sts_ready),
        .s_axis_s2mm_sts_tdata(pack_s2_sts_data),
        .m_axis_s2mm_tvalid(pack_s2_valid),.m_axis_s2mm_tready(pack_s2_ready),
        .m_axis_s2mm_tdata(pack_s2_data),.m_axis_s2mm_tkeep(pack_s2_keep),
        .m_axis_s2mm_tlast(pack_s2_last),.busy(pack_busy),.done(pack_done),
        .error(pack_error),.cycle_count(pack_cycle_count),
        .input_stall_cycles(pack_input_stall),
        .output_stall_cycles(pack_output_stall));

    camus_dual_phase_core u_core (
        .clk,.rst,.clear_history,.enc_start(core_enc_start),
        .dec_start(core_dec_start),.enc_input_base(core_enc_input_base),
        .post_start,.post_logits_base,.post_mask_base,
        .enc_skip_base(core_enc_skip_base),
        .enc_scratch_base(core_enc_scratch_base),
        .dec_mask_base(core_dec_mask_base),.dec_skip_base(core_dec_skip_base),
        .dec_scratch_base(core_dec_scratch_base),.watchdog_limit,
        .enc_mm2s_cmd_valid(core_mm_cmd_valid),
        .enc_mm2s_cmd_ready(core_mm_cmd_ready),
        .enc_mm2s_cmd_data(core_mm_cmd_data),
        .enc_mm2s_sts_valid(core_mm_sts_valid),
        .enc_mm2s_sts_ready(core_mm_sts_ready),
        .enc_mm2s_sts_data(core_mm_sts_data),.enc_mm2s_valid(core_mm_valid),
        .enc_mm2s_ready(core_mm_ready),.enc_mm2s_data(core_mm_data),
        .enc_mm2s_keep(core_mm_keep),.enc_mm2s_last(core_mm_last),
        .enc_s2mm_cmd_valid(core_s2_cmd_valid),
        .enc_s2mm_cmd_ready(core_s2_cmd_ready),
        .enc_s2mm_cmd_data(core_s2_cmd_data),
        .enc_s2mm_sts_valid(core_s2_sts_valid),
        .enc_s2mm_sts_ready(core_s2_sts_ready),
        .enc_s2mm_sts_data(core_s2_sts_data),.enc_s2mm_valid(core_s2_valid),
        .enc_s2mm_ready(core_s2_ready),.enc_s2mm_data(core_s2_data),
        .enc_s2mm_keep(core_s2_keep),.enc_s2mm_last(core_s2_last),
        .dec_mm2s_cmd_valid,.dec_mm2s_cmd_ready,.dec_mm2s_cmd_data,
        .dec_mm2s_sts_valid,.dec_mm2s_sts_ready,.dec_mm2s_sts_data,
        .dec_mm2s_valid,.dec_mm2s_ready,.dec_mm2s_data,.dec_mm2s_keep,
        .dec_mm2s_last,.dec_s2mm_cmd_valid,.dec_s2mm_cmd_ready,
        .dec_s2mm_cmd_data,.dec_s2mm_sts_valid,.dec_s2mm_sts_ready,
        .dec_s2mm_sts_data,.dec_s2mm_valid,.dec_s2mm_ready,.dec_s2mm_data,
        .dec_s2mm_keep,.dec_s2mm_last,.enc_busy(core_enc_busy),
        .enc_done(core_enc_done),.enc_error(core_enc_error),.enc_cycle_count,
        .enc_current_op,.dec_busy(core_dec_busy),.dec_done(core_dec_done),
        .dec_error(core_dec_error),.dec_cycle_count,.dec_current_op,
        .post_mm2s_cmd_valid,.post_mm2s_cmd_ready,.post_mm2s_cmd_data,
        .post_mm2s_sts_valid,.post_mm2s_sts_ready,.post_mm2s_sts_data,
        .post_mm2s_valid,.post_mm2s_ready,.post_mm2s_data,.post_mm2s_keep,
        .post_mm2s_last,.post_s2mm_cmd_valid,.post_s2mm_cmd_ready,
        .post_s2mm_cmd_data,.post_s2mm_sts_valid,.post_s2mm_sts_ready,
        .post_s2mm_sts_data,.post_s2mm_valid,.post_s2mm_ready,.post_s2mm_data,
        .post_s2mm_keep,.post_s2mm_last,.post_busy,.post_done,.post_error,
        .post_cycle_count,.post_current_op,
        .history_count,.history_busy,.history_error,.area_counts(post_areas),
        .profile_rearm, .profile_pack_busy(pack_busy),
        .profile_read_index, .profile_read_data);

    always_comb begin
        enc_mm2s_cmd_valid=encoder_dma_owner_pack
            ?pack_mm_cmd_valid:core_mm_cmd_valid;
        enc_mm2s_cmd_data=encoder_dma_owner_pack
            ?pack_mm_cmd_data:core_mm_cmd_data;
        pack_mm_cmd_ready=encoder_dma_owner_pack?enc_mm2s_cmd_ready:1'b0;
        core_mm_cmd_ready=encoder_dma_owner_pack?1'b0:enc_mm2s_cmd_ready;

        pack_mm_sts_valid=encoder_dma_owner_pack?enc_mm2s_sts_valid:1'b0;
        pack_mm_sts_data=enc_mm2s_sts_data;
        core_mm_sts_valid=encoder_dma_owner_pack?1'b0:enc_mm2s_sts_valid;
        core_mm_sts_data=enc_mm2s_sts_data;
        enc_mm2s_sts_ready=encoder_dma_owner_pack
            ?pack_mm_sts_ready:core_mm_sts_ready;

        pack_mm_valid=encoder_dma_owner_pack?enc_mm2s_valid:1'b0;
        pack_mm_data=enc_mm2s_data;pack_mm_keep=enc_mm2s_keep;
        pack_mm_last=enc_mm2s_last;
        core_mm_valid=encoder_dma_owner_pack?1'b0:enc_mm2s_valid;
        core_mm_data=enc_mm2s_data;core_mm_keep=enc_mm2s_keep;
        core_mm_last=enc_mm2s_last;
        enc_mm2s_ready=encoder_dma_owner_pack?pack_mm_ready:core_mm_ready;

        enc_s2mm_cmd_valid=encoder_dma_owner_pack
            ?pack_s2_cmd_valid:core_s2_cmd_valid;
        enc_s2mm_cmd_data=encoder_dma_owner_pack
            ?pack_s2_cmd_data:core_s2_cmd_data;
        pack_s2_cmd_ready=encoder_dma_owner_pack?enc_s2mm_cmd_ready:1'b0;
        core_s2_cmd_ready=encoder_dma_owner_pack?1'b0:enc_s2mm_cmd_ready;

        pack_s2_sts_valid=encoder_dma_owner_pack?enc_s2mm_sts_valid:1'b0;
        pack_s2_sts_data=enc_s2mm_sts_data;
        core_s2_sts_valid=encoder_dma_owner_pack?1'b0:enc_s2mm_sts_valid;
        core_s2_sts_data=enc_s2mm_sts_data;
        enc_s2mm_sts_ready=encoder_dma_owner_pack
            ?pack_s2_sts_ready:core_s2_sts_ready;

        enc_s2mm_valid=encoder_dma_owner_pack?pack_s2_valid:core_s2_valid;
        enc_s2mm_data=encoder_dma_owner_pack?pack_s2_data:core_s2_data;
        enc_s2mm_keep=encoder_dma_owner_pack?pack_s2_keep:core_s2_keep;
        enc_s2mm_last=encoder_dma_owner_pack?pack_s2_last:core_s2_last;
        pack_s2_ready=encoder_dma_owner_pack?enc_s2mm_ready:1'b0;
        core_s2_ready=encoder_dma_owner_pack?1'b0:enc_s2mm_ready;
    end
endmodule
