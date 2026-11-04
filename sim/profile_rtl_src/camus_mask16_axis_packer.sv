`timescale 1ns/1ps

// Packs one UINT8 class id per pixel into a 128-bit DataMover stream.
module camus_mask16_axis_packer (
    input  logic clk,
    input  logic rst,
    input  logic s_valid,
    output logic s_ready,
    input  logic [7:0] s_class,
    input  logic s_last,
    output logic m_valid,
    input  logic m_ready,
    output logic [127:0] m_data,
    output logic [15:0] m_keep,
    output logic m_last
);
    logic [127:0] assembly_data;
    logic [3:0] assembly_lane;
    logic [127:0] completed_data;

    always_comb begin
        completed_data = assembly_data;
        completed_data[assembly_lane*8 +: 8] = s_class;
    end

    assign s_ready = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            assembly_data <= '0;
            assembly_lane <= '0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_keep <= '0;
            m_last <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;
            if (s_valid && s_ready) begin
                if (s_last || assembly_lane == 4'd15) begin
                    m_valid <= 1'b1;
                    m_data <= completed_data;
                    m_keep <= 16'hffff >> (15-assembly_lane);
                    m_last <= s_last;
                    assembly_data <= '0;
                    assembly_lane <= '0;
                end else begin
                    assembly_data <= completed_data;
                    assembly_lane <= assembly_lane + 1'b1;
                end
            end
        end
    end
endmodule
