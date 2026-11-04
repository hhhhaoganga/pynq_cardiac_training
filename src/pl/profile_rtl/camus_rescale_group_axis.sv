`timescale 1ns/1ps

// Streaming UINT8 Q1.30 rescale. split_lane selects the first lane using the
// high multiplier, allowing dense 4+4 concat without a separate merge pass.
module camus_rescale_group_axis #(
    parameter integer LANES = 8
) (
    input logic clk, input logic rst,
    input logic s_valid, output logic s_ready,
    input logic [LANES*8-1:0] s_data,
    input logic signed [31:0] low_multiplier,
    input logic signed [6:0] low_shift,
    input logic signed [31:0] high_multiplier,
    input logic signed [6:0] high_shift,
    input logic [$clog2(LANES):0] split_lane,
    input logic s_last,
    output logic m_valid, input logic m_ready,
    output logic [LANES*8-1:0] m_data, output logic m_last
);
    logic v0,v1,v2;
    logic last0,last1,last2;
    logic signed [63:0] product[0:LANES-1];
    logic signed [6:0] shift1[0:LANES-1],shift2[0:LANES-1];
    logic signed [63:0] rounded[0:LANES-1], shifted[0:LANES-1];
    logic advance;
    integer lane;
    logic signed [31:0] selected_multiplier;
    logic signed [6:0] selected_shift;

    assign advance=!m_valid||m_ready;
    assign s_ready=advance;
    always_ff @(posedge clk) begin
        if(rst) begin
            v0<=0;v1<=0;v2<=0;m_valid<=0;m_data<=0;m_last<=0;
            last0<=0;last1<=0;last2<=0;
            for(lane=0;lane<LANES;lane=lane+1) begin
                product[lane]<=0;shift1[lane]<=0;rounded[lane]<=0;
                shift2[lane]<=0;shifted[lane]<=0;
            end
        end else if(advance) begin
            m_valid<=v2; m_last<=last2;
            if(v2) for(lane=0;lane<LANES;lane=lane+1) begin
                if(shifted[lane]<0) m_data[lane*8 +:8]<=0;
                else if(shifted[lane]>255) m_data[lane*8 +:8]<=8'hff;
                else m_data[lane*8 +:8]<=shifted[lane][7:0];
            end
            v2<=v1; last2<=last1;
            if(v1) for(lane=0;lane<LANES;lane=lane+1) begin
                if(shift2[lane]>0) shifted[lane]<=rounded[lane]>>>shift2[lane];
                else if(shift2[lane]<0) shifted[lane]<=rounded[lane]<<<(-shift2[lane]);
                else shifted[lane]<=rounded[lane];
            end
            v1<=v0; last1<=last0;
            if(v0) for(lane=0;lane<LANES;lane=lane+1) begin
                rounded[lane]<=shift1[lane]>0
                    ? product[lane]+(64'sd1<<<(shift1[lane]-1'b1)) : product[lane];
                shift2[lane]<=shift1[lane];
            end
            v0<=s_valid; last0<=s_last;
            if(s_valid) for(lane=0;lane<LANES;lane=lane+1) begin
                selected_multiplier = lane<split_lane ? low_multiplier : high_multiplier;
                selected_shift = lane<split_lane ? low_shift : high_shift;
                product[lane]<=$signed({1'b0,s_data[lane*8 +:8]})*selected_multiplier;
                shift1[lane]<=selected_shift;
            end
        end
    end
endmodule
