`timescale 1ns/1ps

module camus_axis128_register_slice (
    input logic clk,
    input logic rst,
    input logic s_valid,
    output logic s_ready,
    input logic [127:0] s_data,
    input logic [15:0] s_keep,
    input logic s_last,
    output logic m_valid,
    input logic m_ready,
    output logic [127:0] m_data,
    output logic [15:0] m_keep,
    output logic m_last
);
    assign s_ready = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_data <= '0;
            m_keep <= '0;
            m_last <= 1'b0;
        end else if (s_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_data <= s_data;
                m_keep <= s_keep;
                m_last <= s_last;
            end
        end
    end
endmodule
