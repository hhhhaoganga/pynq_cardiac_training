`timescale 1ns/1ps

// Two-slot controller for compact input expansion, encoder and decoder.
// Encoder work for frame t+1 overlaps decoder work for frame t.
module camus_frame_pipeline_controller (
    input logic clk,input logic rst,
    input logic frame_valid,output logic frame_ready,
    input logic [31:0] frame_input_base,input logic [31:0] frame_mask_base,
    input logic [31:0] frame_id,
    input logic [31:0] slot0_padded_base,input logic [31:0] slot0_skip_base,
    input logic [31:0] slot0_scratch_base,
    input logic [31:0] slot1_padded_base,input logic [31:0] slot1_skip_base,
    input logic [31:0] slot1_scratch_base,

    output logic pack_start,output logic [31:0] pack_input_base,
    output logic [31:0] pack_output_base,
    input logic pack_done,input logic pack_error,
    output logic enc_start,output logic [31:0] enc_input_base,
    output logic [31:0] enc_skip_base,output logic [31:0] enc_scratch_base,
    input logic enc_done,input logic enc_error,
    output logic dec_start,output logic [31:0] dec_mask_base,
    output logic [31:0] dec_skip_base,output logic [31:0] dec_scratch_base,
    input logic dec_done,input logic dec_error,

    output logic result_valid,input logic result_ready,
    output logic [31:0] result_mask_base,output logic [31:0] result_frame_id,
    output logic encoder_dma_owner_pack,
    output logic busy,output logic error,
    output logic [63:0] frames_accepted,output logic [63:0] frames_completed
);
    localparam logic [1:0] SLOT_FREE=2'd0,SLOT_ENCODER=2'd1;
    localparam logic [1:0] SLOT_READY=2'd2,SLOT_DECODER=2'd3;
    typedef enum logic [2:0] {
        E_IDLE,E_PACK,E_PACK_CHECK,E_ENC,E_ENC_CHECK
    } enc_state_t;
    typedef enum logic [1:0] {D_IDLE,D_RUN,D_CHECK} dec_state_t;

    enc_state_t enc_state;
    dec_state_t dec_state;
    logic [1:0] slot_state[0:1];
    logic [31:0] slot_mask[0:1],slot_frame_id[0:1];
    logic enc_slot,next_enc_slot,dec_slot,next_dec_slot;
    logic accept_frame;

    function automatic logic [31:0] padded_for(input logic slot);
        padded_for=slot?slot1_padded_base:slot0_padded_base;
    endfunction
    function automatic logic [31:0] skip_for(input logic slot);
        skip_for=slot?slot1_skip_base:slot0_skip_base;
    endfunction
    function automatic logic [31:0] scratch_for(input logic slot);
        scratch_for=slot?slot1_scratch_base:slot0_scratch_base;
    endfunction

    assign frame_ready=!error&&enc_state==E_IDLE
        &&slot_state[next_enc_slot]==SLOT_FREE;
    assign accept_frame=frame_valid&&frame_ready;
    assign encoder_dma_owner_pack=enc_state==E_PACK||enc_state==E_PACK_CHECK;
    assign busy=enc_state!=E_IDLE||dec_state!=D_IDLE
        ||slot_state[0]!=SLOT_FREE||slot_state[1]!=SLOT_FREE;

    always_ff @(posedge clk) begin
        if(rst) begin
            enc_state<=E_IDLE;dec_state<=D_IDLE;
            slot_state[0]<=SLOT_FREE;slot_state[1]<=SLOT_FREE;
            slot_mask[0]<=0;slot_mask[1]<=0;
            slot_frame_id[0]<=0;slot_frame_id[1]<=0;
            enc_slot<=0;next_enc_slot<=0;dec_slot<=0;next_dec_slot<=0;
            pack_start<=0;pack_input_base<=0;pack_output_base<=0;
            enc_start<=0;enc_input_base<=0;enc_skip_base<=0;
            enc_scratch_base<=0;dec_start<=0;dec_mask_base<=0;
            dec_skip_base<=0;dec_scratch_base<=0;
            result_valid<=0;result_mask_base<=0;result_frame_id<=0;
            error<=0;frames_accepted<=0;frames_completed<=0;
        end else begin
            pack_start<=0;enc_start<=0;dec_start<=0;
            if(result_valid&&result_ready) result_valid<=0;

            case(enc_state)
                E_IDLE: if(accept_frame) begin
                    enc_slot<=next_enc_slot;
                    slot_state[next_enc_slot]<=SLOT_ENCODER;
                    slot_mask[next_enc_slot]<=frame_mask_base;
                    slot_frame_id[next_enc_slot]<=frame_id;
                    pack_input_base<=frame_input_base;
                    pack_output_base<=padded_for(next_enc_slot);
                    pack_start<=1'b1;enc_state<=E_PACK;
                    frames_accepted<=frames_accepted+1'b1;
                end
                E_PACK: if(pack_done) enc_state<=E_PACK_CHECK;
                E_PACK_CHECK: begin
                    if(pack_error) begin
                        error<=1'b1;slot_state[enc_slot]<=SLOT_FREE;
                        enc_state<=E_IDLE;
                    end else begin
                        enc_input_base<=padded_for(enc_slot);
                        enc_skip_base<=skip_for(enc_slot);
                        enc_scratch_base<=scratch_for(enc_slot);
                        enc_start<=1'b1;enc_state<=E_ENC;
                    end
                end
                E_ENC: if(enc_done) enc_state<=E_ENC_CHECK;
                E_ENC_CHECK: begin
                    if(enc_error) begin
                        error<=1'b1;slot_state[enc_slot]<=SLOT_FREE;
                    end else begin
                        slot_state[enc_slot]<=SLOT_READY;
                        next_enc_slot<=~enc_slot;
                    end
                    enc_state<=E_IDLE;
                end
                default: enc_state<=E_IDLE;
            endcase

            case(dec_state)
                D_IDLE: if(!result_valid
                        &&slot_state[next_dec_slot]==SLOT_READY) begin
                    dec_slot<=next_dec_slot;
                    slot_state[next_dec_slot]<=SLOT_DECODER;
                    dec_mask_base<=slot_mask[next_dec_slot];
                    dec_skip_base<=skip_for(next_dec_slot);
                    dec_scratch_base<=scratch_for(next_dec_slot);
                    dec_start<=1'b1;dec_state<=D_RUN;
                end
                D_RUN: if(dec_done) dec_state<=D_CHECK;
                D_CHECK: begin
                    if(dec_error) begin
                        error<=1'b1;
                    end else begin
                        result_valid<=1'b1;
                        result_mask_base<=slot_mask[dec_slot];
                        result_frame_id<=slot_frame_id[dec_slot];
                        frames_completed<=frames_completed+1'b1;
                    end
                    slot_state[dec_slot]<=SLOT_FREE;
                    next_dec_slot<=~dec_slot;
                    dec_state<=D_IDLE;
                end
                default: dec_state<=D_IDLE;
            endcase
        end
    end
endmodule
