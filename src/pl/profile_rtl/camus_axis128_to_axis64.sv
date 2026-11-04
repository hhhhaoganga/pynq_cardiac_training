`timescale 1ns/1ps

module camus_axis128_to_axis64 (
    input logic clk,
    input logic rst,
    input logic s_valid,
    output logic s_ready,
    input logic [127:0] s_data,
    input logic [15:0] s_keep,
    input logic s_last,
    output logic m_valid,
    input logic m_ready,
    output logic [63:0] m_data,
    output logic m_last,
    output logic error
);
    logic beat_valid, upper;
    logic [127:0] beat_data;
    logic [15:0] beat_keep;
    logic beat_last;
    logic lower_valid, upper_valid;
    logic output_fire, beat_finishing;

    assign lower_valid = beat_keep[7:0] == 8'hff;
    assign upper_valid = beat_keep[15:8] == 8'hff;
    assign output_fire = m_valid && m_ready;
    assign beat_finishing = beat_valid && (upper || !upper_valid);
    // Replace a consumed beat in the same cycle so the 128-to-64 conversion
    // has no bubble between adjacent input beats.
    assign s_ready = !beat_valid || (output_fire && beat_finishing);
    assign m_valid = beat_valid && (upper ? upper_valid : lower_valid);
    assign m_data = upper ? beat_data[127:64] : beat_data[63:0];
    assign m_last = beat_last && (upper || !upper_valid);

    always_ff @(posedge clk) begin
        if (rst) begin
            beat_valid <= 1'b0;
            upper <= 1'b0;
            beat_data <= '0;
            beat_keep <= '0;
            beat_last <= 1'b0;
            error <= 1'b0;
        end else begin
            if (output_fire) begin
                if (!upper && upper_valid)
                    upper <= 1'b1;
                else begin
                    beat_valid <= 1'b0;
                    upper <= 1'b0;
                end
            end

            if (s_valid && s_ready) begin
                beat_valid <= 1'b1;
                upper <= 1'b0;
                beat_data <= s_data;
                beat_keep <= s_keep;
                beat_last <= s_last;
                if (s_keep[7:0] != 8'hff
                        || (s_keep[15:8] != 8'hff && s_keep[15:8] != 8'h00))
                    error <= 1'b1;
            end
        end
    end
endmodule
