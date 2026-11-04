`timescale 1ns/1ps

// Makes the three-bank bottleneck history look like a DataMover S2MM sink to
// the encoder and a DataMover MM2S source to the decoder strip executor.
// Encoder writes and decoder reads are intentionally mutually exclusive.
module camus_history_datamover_bridge #(
    parameter integer DEPTH = 4096,
    parameter integer GROUPS_PER_FRAME = 4,
    parameter bit FIXED_TEMPORAL_STRIPS = 1'b0
) (
    input logic clk,
    input logic rst,
    input logic clear_history,

    input logic enc_cmd_valid,
    output logic enc_cmd_ready,
    input logic [71:0] enc_cmd_data,
    output logic enc_status_valid,
    input logic enc_status_ready,
    output logic [7:0] enc_status_data,
    input logic enc_data_valid,
    output logic enc_data_ready,
    input logic [127:0] enc_data,
    input logic [15:0] enc_keep,
    input logic enc_last,

    input logic dec_cmd_valid,
    output logic dec_cmd_ready,
    input logic [71:0] dec_cmd_data,
    output logic dec_status_valid,
    input logic dec_status_ready,
    output logic [7:0] dec_status_data,
    output logic dec_data_valid,
    input logic dec_data_ready,
    output logic [127:0] dec_data,
    output logic [15:0] dec_keep,
    output logic dec_last,

    output logic [1:0] history_count,
    output logic busy,
    output logic error
);
    localparam integer TEMPORAL_GROUPS = GROUPS_PER_FRAME * 3;
    localparam integer BYTES_PER_TEMPORAL_PIXEL = TEMPORAL_GROUPS * 8;
    localparam integer FRAME_BYTES = DEPTH * 8;

    typedef enum logic [1:0] {ENC_IDLE, ENC_START, ENC_RUN, ENC_STATUS} enc_state_t;
    typedef enum logic [1:0] {DEC_IDLE, DEC_START, DEC_RUN, DEC_STATUS} dec_state_t;
    enc_state_t enc_state;
    dec_state_t dec_state;

    logic history_write_start, history_write_valid, history_write_ready;
    logic [63:0] history_write_data;
    logic history_write_last, history_write_done;
    logic temporal_start, temporal_valid, temporal_ready, temporal_last, temporal_done;
    logic [63:0] temporal_data;
    logic history_error;

    logic enc_slice_valid, enc_slice_ready, enc_slice_last;
    logic [127:0] enc_slice_data;
    logic [15:0] enc_slice_keep;
    logic split_input_ready, split_valid, split_ready, split_last, split_error;
    logic [63:0] split_data;
    logic pack_error;
    logic [3:0] enc_tag, dec_tag;
    logic [22:0] enc_btt;
    logic [23:0] enc_bytes_seen;
    logic [15:0] temporal_first_pixel, temporal_pixels;

    assign busy = enc_state != ENC_IDLE || dec_state != DEC_IDLE;
    assign enc_cmd_ready = enc_state == ENC_IDLE && dec_state == DEC_IDLE
        && !enc_status_valid;
    assign dec_cmd_ready = dec_state == DEC_IDLE && enc_state == ENC_IDLE
        && !dec_status_valid && history_count != 0;
    assign enc_status_data = {1'b1, 3'b000, enc_tag};
    assign dec_status_data = {1'b1, 3'b000, dec_tag};
    assign enc_data_ready = enc_state == ENC_RUN && enc_slice_ready;

    camus_axis128_register_slice u_enc_data_slice (
        .clk(clk), .rst(rst),
        .s_valid(enc_data_valid && enc_state == ENC_RUN),
        .s_ready(enc_slice_ready), .s_data(enc_data), .s_keep(enc_keep),
        .s_last(enc_last), .m_valid(enc_slice_valid),
        .m_ready(split_input_ready), .m_data(enc_slice_data),
        .m_keep(enc_slice_keep), .m_last(enc_slice_last)
    );

    camus_axis128_to_axis64 u_split (
        .clk(clk), .rst(rst), .s_valid(enc_slice_valid),
        .s_ready(split_input_ready), .s_data(enc_slice_data),
        .s_keep(enc_slice_keep), .s_last(enc_slice_last),
        .m_valid(split_valid), .m_ready(split_ready), .m_data(split_data),
        .m_last(split_last), .error(split_error)
    );
    assign history_write_valid = split_valid;
    assign history_write_data = split_data;
    assign history_write_last = split_last;
    assign split_ready = history_write_ready;

    camus_axis64_to_axis128 u_pack (
        .clk(clk), .rst(rst), .s_valid(temporal_valid),
        .s_ready(temporal_ready), .s_data(temporal_data),
        .s_last(temporal_last), .m_valid(dec_data_valid),
        .m_ready(dec_data_ready), .m_data(dec_data), .m_keep(dec_keep),
        .m_last(dec_last), .error(pack_error)
    );

    camus_bottleneck_history #(.DEPTH(DEPTH)) u_history (
        .clk(clk), .rst(rst), .clear_history(clear_history),
        .write_start(history_write_start), .write_valid(history_write_valid),
        .write_ready(history_write_ready), .write_data(history_write_data),
        .write_last(history_write_last), .write_done(history_write_done),
        .temporal_start(temporal_start),
        .temporal_first_pixel(temporal_first_pixel),
        .pixels(temporal_pixels), .groups_per_frame(GROUPS_PER_FRAME[2:0]),
        .temporal_valid(temporal_valid), .temporal_ready(temporal_ready),
        .temporal_data(temporal_data), .temporal_last(temporal_last),
        .temporal_done(temporal_done), .history_count(history_count),
        .error(history_error)
    );

    function automatic [4:0] keep_bytes(input logic [15:0] keep);
        integer bit_index;
        begin
            keep_bytes = 0;
            for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
                keep_bytes = keep_bytes + keep[bit_index];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            enc_state <= ENC_IDLE;
            dec_state <= DEC_IDLE;
            history_write_start <= 1'b0;
            temporal_start <= 1'b0;
            enc_status_valid <= 1'b0;
            dec_status_valid <= 1'b0;
            enc_tag <= 0;
            dec_tag <= 0;
            enc_btt <= 0;
            enc_bytes_seen <= 0;
            temporal_first_pixel <= 0;
            temporal_pixels <= 0;
            error <= 1'b0;
        end else begin
            history_write_start <= 1'b0;
            temporal_start <= 1'b0;

            if (clear_history) begin
                enc_state <= ENC_IDLE;
                dec_state <= DEC_IDLE;
                enc_status_valid <= 1'b0;
                dec_status_valid <= 1'b0;
                error <= 1'b0;
            end else begin
                if (split_error || pack_error || history_error)
                    error <= 1'b1;

                if (enc_status_valid && enc_status_ready)
                    enc_status_valid <= 1'b0;
                if (dec_status_valid && dec_status_ready)
                    dec_status_valid <= 1'b0;

                case (enc_state)
                    ENC_IDLE: if (enc_cmd_valid && enc_cmd_ready) begin
                        enc_tag <= enc_cmd_data[67:64];
                        enc_btt <= enc_cmd_data[22:0];
                        enc_bytes_seen <= 0;
                        if (enc_cmd_data[22:0] != FRAME_BYTES)
                            error <= 1'b1;
                        enc_state <= ENC_START;
                    end
                    ENC_START: begin
                        history_write_start <= 1'b1;
                        enc_state <= ENC_RUN;
                    end
                    ENC_RUN: begin
                        if (enc_slice_valid && split_input_ready) begin
                            enc_bytes_seen <= enc_bytes_seen + keep_bytes(enc_slice_keep);
                            if (enc_slice_last != (enc_bytes_seen
                                    + keep_bytes(enc_slice_keep) == enc_btt))
                                error <= 1'b1;
                        end
                        if (history_write_done) begin
                            if (enc_bytes_seen != enc_btt)
                                error <= 1'b1;
                            enc_status_valid <= 1'b1;
                            enc_state <= ENC_STATUS;
                        end
                    end
                    ENC_STATUS: if (enc_status_valid && enc_status_ready)
                        enc_state <= ENC_IDLE;
                    default: enc_state <= ENC_IDLE;
                endcase

                case (dec_state)
                    DEC_IDLE: if (dec_cmd_valid && dec_cmd_ready) begin
                        dec_tag <= dec_cmd_data[67:64];
                        if (FIXED_TEMPORAL_STRIPS) begin
                            // temporal.0 is frozen at 32x32x96 with 10-row
                            // strips.  Constant decode removes a wide /96 and
                            // %96 path from the complete dual-engine core.
                            case(dec_cmd_data[63:32])
                                32'd0:     temporal_first_pixel<=16'd0;
                                32'd30720: temporal_first_pixel<=16'd320;
                                32'd61440: temporal_first_pixel<=16'd640;
                                32'd92160: temporal_first_pixel<=16'd960;
                                default: begin
                                    temporal_first_pixel<=0;error<=1'b1;
                                end
                            endcase
                            case(dec_cmd_data[22:0])
                                23'd30720: temporal_pixels<=16'd320;
                                23'd6144:  temporal_pixels<=16'd64;
                                default: begin temporal_pixels<=0;error<=1'b1;end
                            endcase
                        end else begin
                            temporal_first_pixel <= dec_cmd_data[63:32]
                                / BYTES_PER_TEMPORAL_PIXEL;
                            temporal_pixels <= dec_cmd_data[22:0]
                                / BYTES_PER_TEMPORAL_PIXEL;
                            if (dec_cmd_data[22:0] == 0
                                    || dec_cmd_data[22:0] % BYTES_PER_TEMPORAL_PIXEL != 0
                                    || dec_cmd_data[63:32] % BYTES_PER_TEMPORAL_PIXEL != 0
                                    || (dec_cmd_data[63:32] / BYTES_PER_TEMPORAL_PIXEL
                                        + dec_cmd_data[22:0] / BYTES_PER_TEMPORAL_PIXEL)
                                        * GROUPS_PER_FRAME > DEPTH)
                                error <= 1'b1;
                        end
                        dec_state <= DEC_START;
                    end
                    DEC_START: begin
                        temporal_start <= 1'b1;
                        dec_state <= DEC_RUN;
                    end
                    DEC_RUN: begin
                        if (dec_data_valid && dec_data_ready && dec_last) begin
                            dec_status_valid <= 1'b1;
                            dec_state <= DEC_STATUS;
                        end
                    end
                    DEC_STATUS: if (dec_status_valid && dec_status_ready)
                        dec_state <= DEC_IDLE;
                    default: dec_state <= DEC_IDLE;
                endcase
            end
        end
    end
endmodule
