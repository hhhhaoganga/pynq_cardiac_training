`timescale 1ns/1ps

// One-pixel-per-cycle signed INT8 argmax for background/LV/MYO/LA logits.
// Ties select the lowest class index, matching numpy.argmax.
module camus_argmax4_axis (
    input  logic clk,
    input  logic rst,
    input  logic s_valid,
    output logic s_ready,
    input  logic [31:0] s_logits,
    input  logic s_last,
    output logic m_valid,
    input  logic m_ready,
    output logic [7:0] m_class,
    output logic m_last
);
    logic stage1_valid;
    logic signed [7:0] stage1_value01, stage1_value23;
    logic [1:0] stage1_class01, stage1_class23;
    logic stage1_last;
    logic stage2_ready;

    assign stage2_ready = !m_valid || m_ready;
    assign s_ready = !stage1_valid || stage2_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_class <= '0;
            m_last <= 1'b0;
            stage1_valid <= 1'b0;
            stage1_value01 <= '0;
            stage1_value23 <= '0;
            stage1_class01 <= '0;
            stage1_class23 <= '0;
            stage1_last <= 1'b0;
        end else begin
            if (stage2_ready)
                m_valid <= stage1_valid;

            if (stage2_ready && stage1_valid) begin
                if (stage1_value01 >= stage1_value23)
                    m_class <= {6'd0, stage1_class01};
                else
                    m_class <= {6'd0, stage1_class23};
                m_last <= stage1_last;
            end

            if (s_ready) begin
                stage1_valid <= s_valid;
                if (s_valid) begin
                if ($signed(s_logits[7:0]) >= $signed(s_logits[15:8])) begin
                    stage1_value01 <= $signed(s_logits[7:0]);
                    stage1_class01 <= 2'd0;
                end else begin
                    stage1_value01 <= $signed(s_logits[15:8]);
                    stage1_class01 <= 2'd1;
                end
                if ($signed(s_logits[23:16]) >= $signed(s_logits[31:24])) begin
                    stage1_value23 <= $signed(s_logits[23:16]);
                    stage1_class23 <= 2'd2;
                end else begin
                    stage1_value23 <= $signed(s_logits[31:24]);
                    stage1_class23 <= 2'd3;
                end
                stage1_last <= s_last;
                end
            end
        end
    end
endmodule
