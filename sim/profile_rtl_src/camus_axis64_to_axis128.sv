`timescale 1ns/1ps

module camus_axis64_to_axis128 (
    input logic clk,
    input logic rst,
    input logic s_valid,
    output logic s_ready,
    input logic [63:0] s_data,
    input logic s_last,
    output logic m_valid,
    input logic m_ready,
    output logic [127:0] m_data,
    output logic [15:0] m_keep,
    output logic m_last,
    output logic error
);
    logic half_valid;
    logic [63:0] lower_data;

    // half_valid never coexists with m_valid. A new word can therefore be
    // accepted whenever the output register is empty or is consumed now.
    assign s_ready = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            half_valid <= 1'b0;
            lower_data <= '0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_keep <= '0;
            m_last <= 1'b0;
            error <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (s_valid && s_ready) begin
                if (!half_valid) begin
                    if (s_last) begin
                        m_data <= {64'd0, s_data};
                        m_keep <= 16'h00ff;
                        m_last <= 1'b1;
                        m_valid <= 1'b1;
                    end else begin
                        lower_data <= s_data;
                        half_valid <= 1'b1;
                    end
                end else begin
                    m_data <= {s_data, lower_data};
                    m_keep <= 16'hffff;
                    m_last <= s_last;
                    m_valid <= 1'b1;
                    half_valid <= 1'b0;
                end
            end
        end
    end
endmodule
