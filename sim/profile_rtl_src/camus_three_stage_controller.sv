`timescale 1ns/1ps

// Two feature slots feed a three-entry postprocess ring. A feature slot is
// reusable at head completion; logits and LCC labels live in the separate ring.
module camus_three_stage_controller (
    input logic clk, rst,
    input logic frame_valid, output logic frame_ready,
    input logic [31:0] frame_input_base, frame_mask_base, frame_id,
    input logic [31:0] slot0_padded_base, slot0_skip_base, slot0_scratch_base,
    input logic [31:0] slot1_padded_base, slot1_skip_base, slot1_scratch_base,
    input logic [31:0] post_base,
    output logic pack_start,
    output logic [31:0] pack_input_base, pack_output_base,
    input logic pack_done, pack_error,
    output logic enc_start,
    output logic [31:0] enc_input_base, enc_skip_base, enc_scratch_base,
    input logic enc_done, enc_error,
    output logic dec_start,
    output logic [31:0] dec_mask_base, dec_skip_base, dec_scratch_base,
    input logic dec_done, dec_error,
    output logic post_start,
    output logic [31:0] post_logits_base, post_mask_base,
    input logic post_done, post_error,
    input logic [63:0] pack_cycles, enc_cycles, dec_cycles, post_cycles,
    input logic [50:0] post_areas,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_mask_base, result_frame_id,
    output logic [63:0] result_pack_cycles, result_enc_cycles,
    output logic [63:0] result_dec_cycles, result_post_cycles,
    output logic [50:0] result_areas,
    output logic encoder_dma_owner_pack,
    output logic busy, error,
    output logic [63:0] frames_accepted, frames_completed
);
    localparam logic [1:0] FREE=0, ENCODING=1, READY=2, DECODING=3;
    localparam logic [1:0] PP_FREE=0, PP_DECODING=1, PP_READY=2, PP_RUNNING=3;
    typedef enum logic [2:0] {E_IDLE,E_PACK,E_PACK_CHECK,E_ENC,E_ENC_CHECK} enc_t;
    typedef enum logic [1:0] {D_IDLE,D_RUN,D_CHECK} dec_t;
    typedef enum logic [1:0] {P_IDLE,P_RUN,P_CHECK} post_t;
    enc_t enc_state;
    dec_t dec_state;
    post_t post_state;
    logic [1:0] slot_state [0:1], pp_state [0:2];
    logic [31:0] slot_mask [0:1], slot_id [0:1];
    logic [63:0] slot_pack_cycles [0:1], slot_enc_cycles [0:1];
    logic [31:0] pp_mask [0:2], pp_id [0:2], pp_logits [0:2];
    logic [63:0] pp_pack_cycles [0:2], pp_enc_cycles [0:2], pp_dec_cycles [0:2];
    logic enc_slot,next_enc_slot,dec_slot,next_dec_slot;
    logic [1:0] alloc_post,read_post,dec_post,active_post;
    integer i;

    function automatic logic [1:0] advance_post(input logic [1:0] index);
        advance_post=index==2 ? 2'd0 : index+1'b1;
    endfunction
    function automatic logic [31:0] logits_for(input logic [1:0] index);
        logits_for=post_base+({30'd0,index}<<20);
    endfunction
    assign frame_ready=!error && post_base!=0 && post_base[19:0]==0
        && enc_state==E_IDLE && slot_state[next_enc_slot]==FREE;
    assign encoder_dma_owner_pack=enc_state==E_PACK || enc_state==E_PACK_CHECK;
    assign busy=enc_state!=E_IDLE || dec_state!=D_IDLE || post_state!=P_IDLE
        || slot_state[0]!=FREE || slot_state[1]!=FREE
        || pp_state[0]!=PP_FREE || pp_state[1]!=PP_FREE || pp_state[2]!=PP_FREE
        || result_valid;

    always_ff @(posedge clk) begin
        if(rst) begin
            enc_state<=E_IDLE; dec_state<=D_IDLE; post_state<=P_IDLE;
            enc_slot<=0; next_enc_slot<=0; dec_slot<=0; next_dec_slot<=0;
            alloc_post<=0; read_post<=0; dec_post<=0; active_post<=0;
            pack_start<=0; enc_start<=0; dec_start<=0; post_start<=0;
            pack_input_base<=0; pack_output_base<=0;
            enc_input_base<=0; enc_skip_base<=0; enc_scratch_base<=0;
            dec_mask_base<=0; dec_skip_base<=0; dec_scratch_base<=0;
            post_logits_base<=0; post_mask_base<=0;
            result_valid<=0; result_mask_base<=0; result_frame_id<=0;
            result_pack_cycles<=0; result_enc_cycles<=0;
            result_dec_cycles<=0; result_post_cycles<=0; result_areas<=0;
            frames_accepted<=0; frames_completed<=0; error<=0;
            for(i=0;i<2;i=i+1) begin
                slot_state[i]<=FREE; slot_mask[i]<=0; slot_id[i]<=0;
                slot_pack_cycles[i]<=0; slot_enc_cycles[i]<=0;
            end
            for(i=0;i<3;i=i+1) begin
                pp_state[i]<=PP_FREE; pp_mask[i]<=0; pp_id[i]<=0; pp_logits[i]<=0;
                pp_pack_cycles[i]<=0; pp_enc_cycles[i]<=0; pp_dec_cycles[i]<=0;
            end
        end else begin
            pack_start<=0; enc_start<=0; dec_start<=0; post_start<=0;
            if(result_valid && result_ready) result_valid<=0;
            if(pack_error || enc_error || dec_error || post_error) error<=1;
            case(enc_state)
                E_IDLE: if(frame_valid && frame_ready) begin
                    enc_slot<=next_enc_slot;
                    slot_state[next_enc_slot]<=ENCODING;
                    slot_mask[next_enc_slot]<=frame_mask_base;
                    slot_id[next_enc_slot]<=frame_id;
                    pack_input_base<=frame_input_base;
                    pack_output_base<=next_enc_slot ? slot1_padded_base : slot0_padded_base;
                    pack_start<=1; enc_state<=E_PACK;
                    frames_accepted<=frames_accepted+1'b1;
                end
                E_PACK: if(pack_done) enc_state<=E_PACK_CHECK;
                E_PACK_CHECK: if(!error && !pack_error) begin
                    slot_pack_cycles[enc_slot]<=pack_cycles;
                    enc_input_base<=enc_slot ? slot1_padded_base : slot0_padded_base;
                    enc_skip_base<=enc_slot ? slot1_skip_base : slot0_skip_base;
                    enc_scratch_base<=enc_slot ? slot1_scratch_base : slot0_scratch_base;
                    enc_start<=1; enc_state<=E_ENC;
                end
                E_ENC: if(enc_done) enc_state<=E_ENC_CHECK;
                E_ENC_CHECK: if(!error && !enc_error) begin
                    slot_enc_cycles[enc_slot]<=enc_cycles;
                    slot_state[enc_slot]<=READY;
                    next_enc_slot<=~enc_slot;
                    enc_state<=E_IDLE;
                end
                default: ;
            endcase
            case(dec_state)
                D_IDLE: if(!error && slot_state[next_dec_slot]==READY
                        && pp_state[alloc_post]==PP_FREE) begin
                    dec_slot<=next_dec_slot;
                    dec_post<=alloc_post;
                    slot_state[next_dec_slot]<=DECODING;
                    pp_state[alloc_post]<=PP_DECODING;
                    pp_mask[alloc_post]<=slot_mask[next_dec_slot];
                    pp_id[alloc_post]<=slot_id[next_dec_slot];
                    pp_logits[alloc_post]<=logits_for(alloc_post);
                    pp_pack_cycles[alloc_post]<=slot_pack_cycles[next_dec_slot];
                    pp_enc_cycles[alloc_post]<=slot_enc_cycles[next_dec_slot];
                    dec_mask_base<=logits_for(alloc_post);
                    dec_skip_base<=next_dec_slot ? slot1_skip_base : slot0_skip_base;
                    dec_scratch_base<=next_dec_slot ? slot1_scratch_base : slot0_scratch_base;
                    alloc_post<=advance_post(alloc_post);
                    dec_start<=1; dec_state<=D_RUN;
                end
                D_RUN: if(dec_done) dec_state<=D_CHECK;
                D_CHECK: if(!error && !dec_error) begin
                    pp_dec_cycles[dec_post]<=dec_cycles;
                    pp_state[dec_post]<=PP_READY;
                    slot_state[dec_slot]<=FREE;
                    next_dec_slot<=~dec_slot;
                    dec_state<=D_IDLE;
                end
                default: ;
            endcase
            case(post_state)
                P_IDLE: if(!error && !result_valid && pp_state[read_post]==PP_READY) begin
                    active_post<=read_post;
                    post_logits_base<=pp_logits[read_post];
                    post_mask_base<=pp_mask[read_post];
                    pp_state[read_post]<=PP_RUNNING;
                    post_start<=1; post_state<=P_RUN;
                end
                P_RUN: if(post_done) post_state<=P_CHECK;
                P_CHECK: if(!error && !post_error) begin
                    result_mask_base<=pp_mask[active_post];
                    result_frame_id<=pp_id[active_post];
                    result_pack_cycles<=pp_pack_cycles[active_post];
                    result_enc_cycles<=pp_enc_cycles[active_post];
                    result_dec_cycles<=pp_dec_cycles[active_post];
                    result_post_cycles<=post_cycles;
                    result_areas<=post_areas;
                    result_valid<=1;
                    frames_completed<=frames_completed+1'b1;
                    pp_state[active_post]<=PP_FREE;
                    read_post<=advance_post(active_post);
                    post_state<=P_IDLE;
                end
                default: ;
            endcase
        end
    end
endmodule
