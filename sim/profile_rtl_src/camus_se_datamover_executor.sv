`timescale 1ns/1ps

// Standalone decoder SE stage. The stage receives one 32x32x32 UINT8
// temporal tensor, computes GAP -> se.1 -> se.3/Hardsigmoid -> feature gate,
// and writes the requantized 32x32x32 tensor for dec3.project.0.
module camus_se_datamover_executor #(
    parameter SE1_WEIGHT_INIT = "se1_weights.mem",
    parameter SE1_BIAS_INIT = "se1_bias.mem",
    parameter SE1_MULT_INIT = "se1_multiplier.mem",
    parameter SE1_SHIFT_INIT = "se1_shift.mem",
    parameter SE3_WEIGHT_INIT = "se3_weights.mem",
    parameter SE3_BIAS_INIT = "se3_bias.mem",
    parameter SE3_GATE_MULT_INIT = "se3_gate_multiplier.mem",
    parameter SE3_GATE_SHIFT_INIT = "se3_gate_shift.mem"
) (
    input logic clk, input logic rst, input logic start,
    input logic [31:0] input_base_bytes, input logic [31:0] output_base_bytes,
    input logic [3:0] command_tag, input logic [31:0] watchdog_limit,
    input logic signed [31:0] gap_multiplier,
    input logic signed [6:0] gap_shift,
    input logic signed [31:0] se1_to_se3_multiplier,
    input logic signed [6:0] se1_to_se3_shift,
    input logic signed [31:0] product_multiplier,
    input logic signed [6:0] product_shift,

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
    output logic [63:0] cycle_count
);
    localparam integer BYTES = 32768;
    localparam integer BEATS = 2048;
    localparam integer PIXELS = 1024;
    localparam integer CHANNELS = 32;
    localparam integer SE1_GROUPS = 2;
    localparam integer SE1_WEIGHT_WORDS = 8;
    localparam integer SE3_GROUPS = 8;

    typedef enum logic [4:0] {
        S_IDLE, S_MM_ISSUE, S_MM_LOAD, S_GAP, S_SE1, S_SE1_STORE, S_SE3, S_SE3_GATE,
        S_OUT_ISSUE, S_OUT_READ, S_OUT_CALC, S_OUT_STREAM, S_WAIT,
        S_GAP_WAIT, S_SE1_WAIT, S_HIDDEN, S_HIDDEN_WAIT, S_GATE_WAIT, S_OUT_DRAIN,
        S_SE1_ACC, S_SE3_ACC, S_OUT_SELECT, S_OUT_REQUEST
    } state_t;
    state_t state;

    (* ram_style = "block" *) logic [127:0] input_mem [0:BEATS-1];
    logic [127:0] input_word, output_word;
    logic [4:0] output_lane;
    logic signed [31:0] gap_sum [0:CHANNELS-1];
    logic [7:0] gap_q [0:CHANNELS-1];
    logic [4:0] gap_index;
    logic [7:0] se1_q [0:7];
    logic [7:0] se3_q [0:7];
    logic [2:0] hidden_index;
    logic [7:0] gate_q [0:31];
    logic [127:0] se1_weight_memory [0:SE1_WEIGHT_WORDS-1];
    logic [127:0] se1_bias_memory [0:SE1_GROUPS-1];
    logic [127:0] se1_mult_memory [0:SE1_GROUPS-1];
    logic [27:0] se1_shift_memory [0:SE1_GROUPS-1];
    logic [127:0] se3_weight_memory [0:SE3_GROUPS-1];
    logic [127:0] se3_bias_memory [0:SE3_GROUPS-1];
    logic [127:0] se3_gate_mult_memory [0:SE3_GROUPS-1];
    logic [27:0] se3_gate_shift_memory [0:SE3_GROUPS-1];

    logic [3:0] tag_reg;
    logic [31:0] input_base_reg, output_base_reg;
    logic [11:0] mm_beat;
    logic [11:0] out_beat;
    logic [3:0] se1_index;
    logic [5:0] se1_input_index;
    logic [5:0] se3_index;
    logic [3:0] se3_input_index;
    logic signed [31:0] fc_accumulator;
    logic [5:0] gate_pending_index;
    logic signed [12:0] fc_product;
    logic [7:0] output_activation, output_gate;
    logic [15:0] output_product;
    logic mm_data_done, mm_status_seen, output_done_seen, s2_status_seen;

    initial begin
        $readmemh(SE1_WEIGHT_INIT, se1_weight_memory);
        $readmemh(SE1_BIAS_INIT, se1_bias_memory);
        $readmemh(SE1_MULT_INIT, se1_mult_memory);
        $readmemh(SE1_SHIFT_INIT, se1_shift_memory);
        $readmemh(SE3_WEIGHT_INIT, se3_weight_memory);
        $readmemh(SE3_BIAS_INIT, se3_bias_memory);
        $readmemh(SE3_GATE_MULT_INIT, se3_gate_mult_memory);
        $readmemh(SE3_GATE_SHIFT_INIT, se3_gate_shift_memory);
    end

    function automatic signed [31:0] word_lane32(
        input logic [127:0] word, input integer lane
    );
        word_lane32 = $signed(word[lane*32 +: 32]);
    endfunction

    function automatic signed [6:0] word_lane7(
        input logic [27:0] word, input integer lane
    );
        word_lane7 = $signed(word[lane*7 +: 7]);
    endfunction

    function automatic [7:0] clamp_u8(input signed [63:0] value);
        begin
            if (value < 0) clamp_u8 = 8'd0;
            else if (value > 255) clamp_u8 = 8'd255;
            else clamp_u8 = value[7:0];
        end
    endfunction

    function automatic signed [4:0] nibble_weight(
        input logic [127:0] word, input integer lane
    );
        reg [3:0] nibble;
        begin
            nibble = word[lane*4 +: 4];
            nibble_weight = $signed({nibble[3], nibble});
        end
    endfunction

    function automatic signed [12:0] mul_u8_s5(
        input logic [7:0] activation,
        input logic signed [4:0] weight
    );
        reg signed [8:0] signed_activation;
        begin
            signed_activation = $signed({1'b0, activation});
            mul_u8_s5 = signed_activation * weight;
        end
    endfunction

    // Shared fully registered quantizer. One request per clock, ten stages.
    // Four 16-bit partial products avoid a cascaded 32x32 DSP multiply.
    logic rq_valid, rq_gate;
    logic signed [31:0] rq_value, rq_multiplier;
    logic signed [6:0] rq_shift;
    logic [9:0] qvalid;
    logic signed [6:0] qshift [0:9];
    logic [9:0] qgate;
    logic [3:0] qlane [0:9];
    logic signed [31:0] qvalue0, qmult0;
    logic signed [33:0] p00, p01, p10, p11;
    logic signed [63:0] qlo2, qhi2, qproduct3, qoffset4;
    logic signed [63:0] qabs5, qround6, qshift7, qsign8, qfinal9;
    logic neg5, neg6, neg7;
    wire [7:0] rq_result = clamp_u8(qfinal9);
    integer qi;

    always_comb begin
        rq_valid = 1'b1;
        rq_gate = 1'b0;
        rq_value = 0; rq_multiplier = 0; rq_shift = 0;
        case (state)
            S_GAP: begin
                rq_value = gap_sum[gap_index];
                rq_multiplier = gap_multiplier; rq_shift = gap_shift;
            end
            S_SE1_STORE: begin
                rq_value = fc_accumulator;
                rq_multiplier = word_lane32(se1_mult_memory[se1_index / 4], se1_index % 4);
                rq_shift = word_lane7(se1_shift_memory[se1_index / 4], se1_index % 4);
            end
            S_HIDDEN: begin
                rq_value = $signed({1'b0, se1_q[hidden_index]});
                rq_multiplier = se1_to_se3_multiplier; rq_shift = se1_to_se3_shift;
            end
            S_SE3_GATE: begin
                rq_value = fc_accumulator; rq_gate = 1'b1;
                rq_multiplier = word_lane32(se3_gate_mult_memory[gate_pending_index / 4], gate_pending_index % 4);
                rq_shift = word_lane7(se3_gate_shift_memory[gate_pending_index / 4], gate_pending_index % 4);
            end
            S_OUT_REQUEST: begin
                rq_value = $signed({1'b0, output_product});
                rq_multiplier = product_multiplier; rq_shift = product_shift;
            end
            default: rq_valid = 1'b0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst || state == S_IDLE) begin
            qvalid <= 0;
        end else begin
            qvalid <= {qvalid[8:0], rq_valid};
            qvalue0 <= rq_value; qmult0 <= rq_multiplier;
            qshift[0] <= rq_shift; qgate[0] <= rq_gate; qlane[0] <= output_lane[3:0];
            for (qi = 1; qi < 10; qi = qi + 1) begin
                qshift[qi] <= qshift[qi-1]; qgate[qi] <= qgate[qi-1]; qlane[qi] <= qlane[qi-1];
            end
            p00 <= $signed({1'b0,qvalue0[15:0]}) * $signed({1'b0,qmult0[15:0]});
            p01 <= $signed({1'b0,qvalue0[15:0]}) * $signed(qmult0[31:16]);
            p10 <= $signed(qvalue0[31:16]) * $signed({1'b0,qmult0[15:0]});
            p11 <= $signed(qvalue0[31:16]) * $signed(qmult0[31:16]);
            qlo2 <= {{30{p00[33]}},p00} + ({{30{p01[33]}},p01} <<< 16);
            qhi2 <= {{30{p10[33]}},p10} + ({{30{p11[33]}},p11} <<< 16);
            qproduct3 <= qlo2 + (qhi2 <<< 16);
            qoffset4 <= qproduct3 + ((qgate[3] && qshift[3] > 0)
                ? (64'sd255 <<< (qshift[3] - 1'b1)) : 64'sd0);
            qabs5 <= qoffset4 < 0 ? -qoffset4 : qoffset4;
            neg5 <= qoffset4 < 0;
            qround6 <= qabs5 + (qshift[5] > 0 ? (64'sd1 <<< (qshift[5] - 1'b1)) : 64'sd0);
            neg6 <= neg5;
            qshift7 <= qshift[6] > 0 ? (qround6 >>> qshift[6]) : (qround6 <<< (-qshift[6]));
            neg7 <= neg6;
            qsign8 <= neg7 ? -qshift7 : qshift7;
            qfinal9 <= qsign8 + ((qgate[8] && qshift[8] <= 0) ? 64'sd128 : 64'sd0);
        end
    end

    integer byte_index;
    integer reset_channel;
    always_comb begin
        m_axis_mm2s_cmd_tdata = '0;
        m_axis_mm2s_cmd_tdata[67:64] = tag_reg;
        m_axis_mm2s_cmd_tdata[63:32] = input_base_reg;
        m_axis_mm2s_cmd_tdata[31] = 1'b1;
        m_axis_mm2s_cmd_tdata[30] = 1'b1;
        m_axis_mm2s_cmd_tdata[23] = 1'b1;
        m_axis_mm2s_cmd_tdata[22:0] = BYTES;
        m_axis_s2mm_cmd_tdata = '0;
        m_axis_s2mm_cmd_tdata[67:64] = tag_reg;
        m_axis_s2mm_cmd_tdata[63:32] = output_base_reg;
        m_axis_s2mm_cmd_tdata[31] = 1'b1;
        m_axis_s2mm_cmd_tdata[30] = 1'b1;
        m_axis_s2mm_cmd_tdata[23] = 1'b1;
        m_axis_s2mm_cmd_tdata[22:0] = BYTES;
        m_axis_s2mm_tdata = output_word;
        m_axis_s2mm_tkeep = 16'hffff;
        m_axis_s2mm_tlast = out_beat == BEATS - 1;
    end

    assign busy = state != S_IDLE;
    assign m_axis_mm2s_cmd_tvalid = state == S_MM_ISSUE;
    assign s_axis_mm2s_tready = state == S_MM_LOAD;
    assign s_axis_mm2s_sts_tready = state == S_MM_LOAD && !mm_status_seen;
    assign m_axis_s2mm_cmd_tvalid = state == S_OUT_ISSUE;
    assign m_axis_s2mm_tvalid = state == S_OUT_STREAM;
    assign s_axis_s2mm_sts_tready = state == S_WAIT && !s2_status_seen;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; error <= 1'b0; cycle_count <= 0;
            tag_reg <= 0; input_base_reg <= 0; output_base_reg <= 0;
            mm_beat <= 0; out_beat <= 0; se1_index <= 0; se1_input_index <= 0;
            se3_index <= 0; se3_input_index <= 0; fc_accumulator <= 0;
            gap_index <= 0; hidden_index <= 0;
            mm_data_done <= 0; mm_status_seen <= 0; output_done_seen <= 0;
            s2_status_seen <= 0;
            input_word <= 0; output_word <= 0; output_lane <= 0;
            fc_product <= 0; output_activation <= 0; output_gate <= 0;
            output_product <= 0;
            for (reset_channel = 0; reset_channel < CHANNELS; reset_channel = reset_channel + 1) begin
                gap_sum[reset_channel] <= 0;
                gap_q[reset_channel] <= 0;
                gate_q[reset_channel] <= 0;
            end
            for (reset_channel = 0; reset_channel < 8; reset_channel = reset_channel + 1)
                se1_q[reset_channel] <= 0;
        end else begin
            done <= 1'b0;
            if (busy) cycle_count <= cycle_count + 1'b1;
            if (start && busy) error <= 1'b1;

            if (state == S_MM_LOAD && s_axis_mm2s_tvalid && s_axis_mm2s_tready) begin
                for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1) begin
                    // One 128-bit feature word is stored per DataMover beat.
                    gap_sum[(mm_beat[0] ? 16 : 0) + byte_index] <=
                        gap_sum[(mm_beat[0] ? 16 : 0) + byte_index]
                        + s_axis_mm2s_tdata[byte_index*8 +: 8];
                end
                input_mem[mm_beat] <= s_axis_mm2s_tdata;
                if (mm_beat == BEATS - 1) mm_data_done <= 1'b1;
                else mm_beat <= mm_beat + 1'b1;
            end
            if (state == S_MM_LOAD && s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready) begin
                mm_status_seen <= 1'b1;
                if (!s_axis_mm2s_sts_tdata[7] || |s_axis_mm2s_sts_tdata[6:4]
                        || s_axis_mm2s_sts_tdata[3:0] != tag_reg) error <= 1'b1;
            end
            if (state == S_WAIT && s_axis_s2mm_sts_tvalid && s_axis_s2mm_sts_tready) begin
                s2_status_seen <= 1'b1;
                if (!s_axis_s2mm_sts_tdata[7] || |s_axis_s2mm_sts_tdata[6:4]
                        || s_axis_s2mm_sts_tdata[3:0] != tag_reg) error <= 1'b1;
            end

            // Collect tagged bytes while requests continue to enter the pipeline.
            if ((state == S_OUT_SELECT || state == S_OUT_CALC || state == S_OUT_REQUEST
                    || state == S_OUT_DRAIN) && qvalid[9]) begin
                output_word[qlane[9]*8 +: 8] <= rq_result;
                if (qlane[9] == 15) state <= S_OUT_STREAM;
            end
            case (state)
                S_IDLE: if (start) begin
                    input_base_reg <= input_base_bytes; output_base_reg <= output_base_bytes;
                    tag_reg <= command_tag; cycle_count <= 0; error <= 0;
                    mm_beat <= 0; out_beat <= 0; mm_data_done <= 0; mm_status_seen <= 0;
                    output_done_seen <= 0; s2_status_seen <= 0;
                    for (reset_channel = 0; reset_channel < CHANNELS; reset_channel = reset_channel + 1)
                        gap_sum[reset_channel] <= 0;
                    state <= S_MM_ISSUE;
                end
                S_MM_ISSUE: if (m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready)
                    state <= S_MM_LOAD;
                S_MM_LOAD: if (mm_data_done && mm_status_seen) begin
                    gap_index <= 0; state <= S_GAP;
                end
                S_GAP: state <= S_GAP_WAIT;
                S_GAP_WAIT: if (qvalid[9]) begin
                    gap_q[gap_index] <= rq_result;
                    if (gap_index == CHANNELS - 1) begin
                        se1_index <= 0; se1_input_index <= 0;
                        fc_accumulator <= word_lane32(se1_bias_memory[0], 0);
                        state <= S_SE1;
                    end else begin gap_index <= gap_index + 1'b1; state <= S_GAP; end
                end
                S_SE1: begin
                    fc_product <= mul_u8_s5(gap_q[se1_input_index],
                        nibble_weight(
                            se1_weight_memory[(se1_index / 4) * 4 + (se1_input_index / 8)],
                            (se1_index % 4) * 8 + (se1_input_index % 8)));
                    state <= S_SE1_ACC;
                end
                S_SE1_ACC: begin
                    fc_accumulator <= fc_accumulator + fc_product;
                    if (se1_input_index == CHANNELS - 1) begin
                        state <= S_SE1_STORE;
                        se1_input_index <= 0;
                    end else begin
                        se1_input_index <= se1_input_index + 1'b1;
                        state <= S_SE1;
                    end
                end
                S_SE1_STORE: state <= S_SE1_WAIT;
                S_SE1_WAIT: if (qvalid[9]) begin
                    se1_q[se1_index] <= rq_result;
                    if (se1_index == 7) begin
                        hidden_index <= 0; state <= S_HIDDEN;
                    end else begin
                        se1_index <= se1_index + 1'b1;
                        fc_accumulator <= word_lane32(se1_bias_memory[(se1_index + 1'b1) / 4], (se1_index + 1'b1) % 4);
                        state <= S_SE1;
                    end
                end
                S_HIDDEN: state <= S_HIDDEN_WAIT;
                S_HIDDEN_WAIT: if (qvalid[9]) begin
                    se3_q[hidden_index] <= rq_result;
                    if (hidden_index == 7) begin
                        se3_index <= 0; se3_input_index <= 0;
                        fc_accumulator <= word_lane32(se3_bias_memory[0], 0);
                        state <= S_SE3;
                    end else begin hidden_index <= hidden_index + 1'b1; state <= S_HIDDEN; end
                end
                S_SE3: begin
                    fc_product <= mul_u8_s5(
                        se3_q[se3_input_index],
                        nibble_weight(se3_weight_memory[se3_index / 4],
                                      (se3_index % 4) * 8 + se3_input_index));
                    state <= S_SE3_ACC;
                end
                S_SE3_ACC: begin
                    fc_accumulator <= fc_accumulator + fc_product;
                    if (se3_input_index == 7) begin
                        gate_pending_index <= se3_index;
                        state <= S_SE3_GATE;
                        se3_input_index <= 0;
                    end else begin
                        se3_input_index <= se3_input_index + 1'b1;
                        state <= S_SE3;
                    end
                end
                S_SE3_GATE: state <= S_GATE_WAIT;
                S_GATE_WAIT: if (qvalid[9]) begin
                    gate_q[gate_pending_index] <= rq_result;
                    if (gate_pending_index == 31) begin
                        out_beat <= 0; state <= S_OUT_ISSUE;
                    end else begin
                        se3_index <= gate_pending_index + 1'b1;
                        fc_accumulator <= word_lane32(
                            se3_bias_memory[(gate_pending_index + 1'b1) / 4],
                            (gate_pending_index + 1'b1) % 4);
                        state <= S_SE3;
                    end
                end
                S_OUT_ISSUE: if (m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready)
                    state <= S_OUT_READ;
                S_OUT_READ: begin
                    input_word <= input_mem[out_beat];
                    output_lane <= 0;
                    state <= S_OUT_SELECT;
                end
                S_OUT_SELECT: begin
                    output_activation <= input_word[output_lane*8 +: 8];
                    output_gate <= gate_q[{out_beat[0], output_lane[3:0]}];
                    state <= S_OUT_CALC;
                end
                S_OUT_CALC: begin
                    output_product <= output_activation * output_gate;
                    state <= S_OUT_REQUEST;
                end
                S_OUT_REQUEST: begin
                    if (output_lane == 15) state <= S_OUT_DRAIN;
                    else begin
                        output_lane <= output_lane + 1'b1;
                        state <= S_OUT_SELECT;
                    end
                end
                S_OUT_DRAIN: begin end
                S_OUT_STREAM: if (m_axis_s2mm_tvalid && m_axis_s2mm_tready) begin
                    if (out_beat == BEATS - 1) begin output_done_seen <= 1'b1; state <= S_WAIT; end
                    else begin out_beat <= out_beat + 1'b1; state <= S_OUT_READ; end
                end
                S_WAIT: if (output_done_seen && s2_status_seen) begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
            if (watchdog_limit != 0 && cycle_count >= watchdog_limit) begin
                error <= 1'b1; done <= 1'b1; state <= S_IDLE;
            end
        end
    end
endmodule
