`timescale 1ns/1ps

// AXI4-Lite register bank for the complete streaming CAMUS accelerator.
// Command bits are write-one pulses; completion and fault bits stay set until
// software acknowledges them or issues a soft reset.
module camus_stream_axi_ctrl #(
    parameter integer ADDR_W = 8
) (
    input  logic s_axi_aclk,
    input  logic s_axi_aresetn,
    input  logic [ADDR_W-1:0] s_axi_awaddr,
    input  logic s_axi_awvalid,
    output logic s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0] s_axi_wstrb,
    input  logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input  logic s_axi_bready,
    input  logic [ADDR_W-1:0] s_axi_araddr,
    input  logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input  logic s_axi_rready,

    output logic submit_pulse,
    output logic soft_reset_pulse,
    output logic clear_history_pulse,
    output logic [31:0] cfg_input_base,
    output logic [31:0] cfg_mask_base,
    output logic [31:0] cfg_frame_id,
    output logic [31:0] cfg_slot0_padded_base,
    output logic [31:0] cfg_slot0_skip_base,
    output logic [31:0] cfg_slot0_scratch_base,
    output logic [31:0] cfg_slot1_padded_base,
    output logic [31:0] cfg_slot1_skip_base,
    output logic [31:0] cfg_slot1_scratch_base,
    output logic [31:0] cfg_watchdog_limit,
    output logic [31:0] cfg_post_base,

    input  logic frame_ready,
    input  logic core_busy,
    input  logic core_error,
    input  logic dma_error,
    input  logic result_valid,
    output logic result_ready,
    input  logic [31:0] result_mask_base,
    input  logic [31:0] result_frame_id,
    input  logic [63:0] frames_accepted,
    input  logic [63:0] frames_completed,
    input  logic [63:0] pack_cycle_count,
    input  logic [63:0] enc_cycle_count,
    input  logic [63:0] dec_cycle_count,
    input  logic [63:0] post_cycle_count,
    input  logic [4:0] enc_current_op,
    input  logic [4:0] dec_current_op,
    input  logic [1:0] history_count,
    input  logic [50:0] area_counts,
    output logic irq,
    output logic profile_rearm,
    output logic [7:0] profile_read_index,
    input logic [31:0] profile_read_data
);
    logic aw_hold, w_hold;
    logic [ADDR_W-1:0] awaddr_hold;
    logic [31:0] wdata_hold;
    logic [3:0] wstrb_hold;
    logic done_sticky, error_sticky, overflow_sticky, irq_enable;
    logic [31:0] last_result_mask_base, last_result_frame_id;
    logic [50:0] last_area_counts;
    logic [63:0] last_pack_cycles, last_enc_cycles, last_dec_cycles, last_post_cycles;

    assign result_ready = !done_sticky && !soft_reset_pulse;
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;
    assign irq = irq_enable && (done_sticky || error_sticky || overflow_sticky);

    function automatic [31:0] read_reg(input logic [ADDR_W-1:0] address);
        begin
            case (address[ADDR_W-1:2])
                5'h00: read_reg = profile_read_data;
                5'h01: read_reg = {22'd0, history_count, 2'd0,
                    frame_ready, overflow_sticky, error_sticky, done_sticky,
                    core_busy};
                5'h02: read_reg = cfg_input_base;
                5'h03: read_reg = cfg_mask_base;
                5'h04: read_reg = cfg_frame_id;
                5'h05: read_reg = cfg_slot0_padded_base;
                5'h06: read_reg = cfg_slot0_skip_base;
                5'h07: read_reg = cfg_slot0_scratch_base;
                5'h08: read_reg = cfg_slot1_padded_base;
                5'h09: read_reg = cfg_slot1_skip_base;
                5'h0a: read_reg = cfg_slot1_scratch_base;
                5'h0b: read_reg = cfg_watchdog_limit;
                5'h0c: read_reg = frames_accepted[31:0];
                5'h0d: read_reg = frames_accepted[63:32];
                5'h0e: read_reg = frames_completed[31:0];
                5'h0f: read_reg = frames_completed[63:32];
                5'h10: read_reg = last_pack_cycles[31:0];
                5'h11: read_reg = last_pack_cycles[63:32];
                5'h12: read_reg = last_enc_cycles[31:0];
                5'h13: read_reg = last_enc_cycles[63:32];
                5'h14: read_reg = last_dec_cycles[31:0];
                5'h15: read_reg = last_dec_cycles[63:32];
                5'h16: read_reg = last_result_mask_base;
                5'h17: read_reg = last_result_frame_id;
                5'h18: read_reg = {10'd0, dec_current_op, 3'd0,
                    enc_current_op, 7'd0, history_count};
                5'h19: read_reg = {31'd0, irq_enable};
                5'h1a: read_reg = 32'h4341_4d55; // "CAMU"
                5'h1b: read_reg = {8'd4, 8'd8, 8'd1, 8'd4}; // classes/SIMD/input/PE
                5'h1c: read_reg = {15'd0, last_area_counts[16:0]};
                5'h1d: read_reg = {15'd0, last_area_counts[33:17]};
                5'h1e: read_reg = {15'd0, last_area_counts[50:34]};
                5'h1f: read_reg = 32'h4152_4531; // "ARE1", final-mask area capability
                6'h20: read_reg = cfg_post_base;
                6'h21: read_reg = 32'h3353_5447; // "3STG"
                6'h22: read_reg = last_post_cycles[31:0];
                6'h23: read_reg = last_post_cycles[63:32];
                default: read_reg = 32'd0;
            endcase
        end
    endfunction

    function automatic [31:0] merge_wstrb(
        input logic [31:0] current,
        input logic [31:0] value,
        input logic [3:0] strobes
    );
        integer lane;
        begin
            merge_wstrb = current;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (strobes[lane])
                    merge_wstrb[lane*8 +: 8] = value[lane*8 +: 8];
        end
    endfunction

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold <= 1'b0;
            w_hold <= 1'b0;
            awaddr_hold <= '0;
            wdata_hold <= '0;
            wstrb_hold <= '0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
            submit_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            clear_history_pulse <= 1'b0;
            cfg_input_base <= 32'd0;
            cfg_mask_base <= 32'd0;
            cfg_frame_id <= 32'd0;
            cfg_slot0_padded_base <= 32'd0;
            cfg_slot0_skip_base <= 32'd0;
            cfg_slot0_scratch_base <= 32'd0;
            cfg_slot1_padded_base <= 32'd0;
            cfg_slot1_skip_base <= 32'd0;
            cfg_slot1_scratch_base <= 32'd0;
            cfg_watchdog_limit <= 32'h3fff_ffff;
            cfg_post_base <= 0;
            last_pack_cycles <= 0;
            last_enc_cycles <= 0;
            last_dec_cycles <= 0;
            last_post_cycles <= 0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            overflow_sticky <= 1'b0;
            irq_enable <= 1'b0;
            last_result_mask_base <= 32'd0;
            last_result_frame_id <= 32'd0;
            last_area_counts <= '0;
            profile_rearm <= 1'b0;
            profile_read_index <= 0;
        end else begin
            submit_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            clear_history_pulse <= 1'b0;

            if (core_error || dma_error)
                error_sticky <= 1'b1;
            profile_rearm <= 1'b0;
            if (result_valid && result_ready) begin
                done_sticky <= 1'b1;
                last_result_mask_base <= result_mask_base;
                last_result_frame_id <= result_frame_id;
                last_area_counts <= area_counts;
                last_pack_cycles <= pack_cycle_count;
                last_enc_cycles <= enc_cycle_count;
                last_dec_cycles <= dec_cycle_count;
                last_post_cycles <= post_cycle_count;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (aw_hold && w_hold && !s_axi_bvalid) begin
                case (awaddr_hold[ADDR_W-1:2])
                    5'h00: begin
                        if (wstrb_hold[0]) begin
                            if (wdata_hold[0]) begin
                                if (frame_ready)
                                    submit_pulse <= 1'b1;
                                else
                                    overflow_sticky <= 1'b1;
                            end
                            soft_reset_pulse <= wdata_hold[1];
                            clear_history_pulse <= wdata_hold[2];
                            if (wdata_hold[3] && !(result_valid && result_ready))
                                done_sticky <= 1'b0;
                            if (wdata_hold[4]) begin
                                error_sticky <= 1'b0;
                                overflow_sticky <= 1'b0;
                            end
                            if (wdata_hold[1]) begin
                                done_sticky <= 1'b0;
                                error_sticky <= 1'b0;
                                overflow_sticky <= 1'b0;
                            end
                        end
                    end
                    5'h02: cfg_input_base <= merge_wstrb(cfg_input_base, wdata_hold, wstrb_hold);
                    5'h03: cfg_mask_base <= merge_wstrb(cfg_mask_base, wdata_hold, wstrb_hold);
                    5'h04: cfg_frame_id <= merge_wstrb(cfg_frame_id, wdata_hold, wstrb_hold);
                    5'h05: cfg_slot0_padded_base <= merge_wstrb(cfg_slot0_padded_base, wdata_hold, wstrb_hold);
                    5'h06: cfg_slot0_skip_base <= merge_wstrb(cfg_slot0_skip_base, wdata_hold, wstrb_hold);
                    5'h07: cfg_slot0_scratch_base <= merge_wstrb(cfg_slot0_scratch_base, wdata_hold, wstrb_hold);
                    5'h08: cfg_slot1_padded_base <= merge_wstrb(cfg_slot1_padded_base, wdata_hold, wstrb_hold);
                    5'h09: cfg_slot1_skip_base <= merge_wstrb(cfg_slot1_skip_base, wdata_hold, wstrb_hold);
                    5'h0a: cfg_slot1_scratch_base <= merge_wstrb(cfg_slot1_scratch_base, wdata_hold, wstrb_hold);
                    5'h0b: cfg_watchdog_limit <= merge_wstrb(cfg_watchdog_limit, wdata_hold, wstrb_hold);
                    6'h20: cfg_post_base <= merge_wstrb(cfg_post_base, wdata_hold, wstrb_hold);
                    5'h19: if (wstrb_hold[0]) irq_enable <= wdata_hold[0];
                    5'h18: begin
                        if (wstrb_hold[0]) profile_read_index <= wdata_hold[7:0];
                        if (wstrb_hold[3]) profile_rearm <= wdata_hold[31];
                    end
                    default: ;
                endcase
                aw_hold <= 1'b0;
                w_hold <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rdata <= read_reg(s_axi_araddr);
                s_axi_rvalid <= 1'b1;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end
endmodule
