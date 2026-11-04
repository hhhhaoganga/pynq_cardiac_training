`timescale 1ns/1ps

// Collects one pixel from each decoder branch, rescales both UINT8 tensors to
// the refine-layer input scale, and emits densely packed SIMD8 groups. This
// handles 4+4 channels as one word instead of inserting four padding lanes.
module camus_concat_rescale_axis #(
    parameter integer MAX_A_CHANNELS = 32,
    parameter integer MAX_B_CHANNELS = 16
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [5:0] a_channels,
    input  logic [5:0] b_channels,
    input  logic signed [31:0] a_multiplier,
    input  logic signed [6:0] a_shift,
    input  logic signed [31:0] b_multiplier,
    input  logic signed [6:0] b_shift,

    input  logic a_valid,
    output logic a_ready,
    input  logic [63:0] a_data,
    input  logic a_last_group,
    input  logic b_valid,
    output logic b_ready,
    input  logic [63:0] b_data,
    input  logic b_last_group,

    output logic m_valid,
    input  logic m_ready,
    output logic [63:0] m_data,
    output logic m_last_group,
    output logic pixel_done,
    output logic busy,
    output logic error
);
    localparam integer MAX_A_GROUPS = (MAX_A_CHANNELS + 7) / 8;
    localparam integer MAX_B_GROUPS = (MAX_B_CHANNELS + 7) / 8;

    typedef enum logic [1:0] {S_IDLE, S_COLLECT, S_EMIT, S_DRAIN} state_t;
    state_t state;

    logic [MAX_A_CHANNELS*8-1:0] a_storage;
    logic [MAX_B_CHANNELS*8-1:0] b_storage;
    logic [2:0] a_group_count, b_group_count;
    logic [2:0] a_groups_reg, b_groups_reg, output_groups_reg;
    logic [5:0] a_channels_reg, b_channels_reg, total_channels_reg;
    logic signed [31:0] a_multiplier_reg, b_multiplier_reg;
    logic signed [6:0] a_shift_reg, b_shift_reg;
    logic a_complete, b_complete;
    logic a_fire, b_fire;
    logic [2:0] emit_group;

    logic prep_valid;
    logic prep_last;
    logic [7:0] lane_value [0:7];
    logic signed [31:0] lane_multiplier [0:7];
    logic signed [6:0] prep_shift [0:7];
    logic product_valid;
    logic product_last;
    logic signed [63:0] lane_product [0:7];
    logic signed [6:0] lane_shift [0:7];
    logic rounded_valid, rounded_last;
    logic [63:0] lane_rounded [0:7];
    logic signed [6:0] rounded_shift [0:7];
    logic shifted_valid, shifted_last;
    logic [63:0] lane_shifted [0:7];
    logic pipeline_advance;

    integer lane;
    integer source_channel;
    logic [7:0] source_value;
    logic signed [31:0] source_multiplier;
    logic signed [6:0] source_shift;

    assign busy = state != S_IDLE;
    assign a_ready = state == S_COLLECT && !a_complete;
    assign b_ready = state == S_COLLECT && !b_complete;
    assign a_fire = a_valid && a_ready;
    assign b_fire = b_valid && b_ready;
    assign pipeline_advance = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            a_storage <= '0;
            b_storage <= '0;
            a_group_count <= '0;
            b_group_count <= '0;
            a_groups_reg <= '0;
            b_groups_reg <= '0;
            output_groups_reg <= '0;
            a_channels_reg <= '0;
            b_channels_reg <= '0;
            total_channels_reg <= '0;
            a_multiplier_reg <= '0;
            b_multiplier_reg <= '0;
            a_shift_reg <= '0;
            b_shift_reg <= '0;
            a_complete <= 1'b0;
            b_complete <= 1'b0;
            emit_group <= '0;
            prep_valid <= 1'b0;
            prep_last <= 1'b0;
            product_valid <= 1'b0;
            product_last <= 1'b0;
            rounded_valid <= 1'b0;
            rounded_last <= 1'b0;
            shifted_valid <= 1'b0;
            shifted_last <= 1'b0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_last_group <= 1'b0;
            pixel_done <= 1'b0;
            error <= 1'b0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                lane_value[lane] <= '0;
                lane_multiplier[lane] <= '0;
                prep_shift[lane] <= '0;
                lane_product[lane] <= '0;
                lane_shift[lane] <= '0;
                lane_rounded[lane] <= '0;
                rounded_shift[lane] <= '0;
                lane_shifted[lane] <= '0;
            end
        end else begin
            pixel_done <= 1'b0;

            // One globally stalled elastic pipeline is sufficient here: the
            // downstream only backpressures complete SIMD8 groups.
            if (pipeline_advance) begin
                m_valid <= shifted_valid;
                if (shifted_valid) begin
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        if (lane_shifted[lane] > 255)
                            m_data[lane*8 +: 8] <= 8'hff;
                        else
                            m_data[lane*8 +: 8] <= lane_shifted[lane][7:0];
                    end
                    m_last_group <= shifted_last;
                end

                shifted_valid <= rounded_valid;
                shifted_last <= rounded_last;
                if (rounded_valid) begin
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        if (rounded_shift[lane] > 0)
                            lane_shifted[lane] <= lane_rounded[lane] >> rounded_shift[lane];
                        else if (rounded_shift[lane] < 0)
                            lane_shifted[lane] <= lane_rounded[lane] << (-rounded_shift[lane]);
                        else
                            lane_shifted[lane] <= lane_rounded[lane];
                    end
                end

                rounded_valid <= product_valid;
                rounded_last <= product_last;
                if (product_valid) begin
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        lane_rounded[lane] <= lane_shift[lane] > 0
                            ? lane_product[lane] + (64'd1 << (lane_shift[lane] - 1'b1))
                            : lane_product[lane];
                        rounded_shift[lane] <= lane_shift[lane];
                    end
                end

                product_valid <= prep_valid;
                product_last <= prep_last;
                if (prep_valid) begin
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        lane_product[lane] <= $signed({1'b0, lane_value[lane]})
                            * lane_multiplier[lane];
                        lane_shift[lane] <= prep_shift[lane];
                    end
                end
                prep_valid <= 1'b0;
            end

            if (start) begin
                if (busy || a_channels == 0 || b_channels == 0
                        || a_channels > MAX_A_CHANNELS
                        || b_channels > MAX_B_CHANNELS) begin
                    error <= 1'b1;
                end else begin
                    a_channels_reg <= a_channels;
                    b_channels_reg <= b_channels;
                    total_channels_reg <= a_channels + b_channels;
                    a_groups_reg <= (a_channels + 7) >> 3;
                    b_groups_reg <= (b_channels + 7) >> 3;
                    output_groups_reg <= (a_channels + b_channels + 7) >> 3;
                    a_multiplier_reg <= a_multiplier;
                    a_shift_reg <= a_shift;
                    b_multiplier_reg <= b_multiplier;
                    b_shift_reg <= b_shift;
                    a_group_count <= 0;
                    b_group_count <= 0;
                    a_complete <= 1'b0;
                    b_complete <= 1'b0;
                    a_storage <= '0;
                    b_storage <= '0;
                    product_valid <= 1'b0;
                    prep_valid <= 1'b0;
                    rounded_valid <= 1'b0;
                    shifted_valid <= 1'b0;
                    m_valid <= 1'b0;
                    state <= S_COLLECT;
                    error <= 1'b0;
                end
            end else begin
                case (state)
                    S_COLLECT: begin
                        if (a_fire) begin
                            a_storage[a_group_count*64 +: 64] <= a_data;
                            if (a_last_group != (a_group_count == a_groups_reg - 1'b1))
                                error <= 1'b1;
                            if (a_group_count == a_groups_reg - 1'b1)
                                a_complete <= 1'b1;
                            else
                                a_group_count <= a_group_count + 1'b1;
                        end
                        if (b_fire) begin
                            b_storage[b_group_count*64 +: 64] <= b_data;
                            if (b_last_group != (b_group_count == b_groups_reg - 1'b1))
                                error <= 1'b1;
                            if (b_group_count == b_groups_reg - 1'b1)
                                b_complete <= 1'b1;
                            else
                                b_group_count <= b_group_count + 1'b1;
                        end
                        if ((a_complete || (a_fire && a_group_count == a_groups_reg - 1'b1))
                                && (b_complete || (b_fire && b_group_count == b_groups_reg - 1'b1))) begin
                            emit_group <= 0;
                            state <= S_EMIT;
                        end
                    end

                    S_EMIT: if (pipeline_advance) begin
                        for (lane = 0; lane < 8; lane = lane + 1) begin
                            source_channel = emit_group*8 + lane;
                            if (source_channel < a_channels_reg) begin
                                source_value = a_storage[source_channel*8 +: 8];
                                source_multiplier = a_multiplier_reg;
                                source_shift = a_shift_reg;
                            end else if (source_channel < total_channels_reg) begin
                                source_value = b_storage[(source_channel-a_channels_reg)*8 +: 8];
                                source_multiplier = b_multiplier_reg;
                                source_shift = b_shift_reg;
                            end else begin
                                source_value = 0;
                                source_multiplier = 0;
                                source_shift = 0;
                            end
                            lane_value[lane] <= source_value;
                            lane_multiplier[lane] <= source_multiplier;
                            prep_shift[lane] <= source_shift;
                        end
                        prep_valid <= 1'b1;
                        prep_last <= emit_group == output_groups_reg - 1'b1;
                        if (emit_group == output_groups_reg - 1'b1)
                            state <= S_DRAIN;
                        else
                            emit_group <= emit_group + 1'b1;
                    end

                    S_DRAIN: if (!prep_valid && !product_valid
                            && !rounded_valid && !shifted_valid
                            && (!m_valid || m_ready)) begin
                        pixel_done <= 1'b1;
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
