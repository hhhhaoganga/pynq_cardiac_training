`timescale 1ns/1ps

module camus_axis128_to_u16 (
    input logic clk,input logic rst,
    input logic s_valid,output logic s_ready,
    input logic [127:0] s_data,input logic [15:0] s_keep,input logic s_last,
    output logic m_valid,input logic m_ready,
    output logic [15:0] m_data,output logic m_last,output logic error
);
    logic hold_valid,hold_last;
    logic [127:0] hold_data;
    logic [15:0] hold_keep;
    logic [3:0] lane,last_lane;
    integer comb_index;
    integer seq_index;

    assign s_ready=!hold_valid;
    assign m_valid=hold_valid&&hold_keep[lane*2]&&hold_keep[lane*2+1];
    assign m_data=hold_data[lane*16 +: 16];
    assign m_last=hold_last&&lane==last_lane;

    always_comb begin
        last_lane=0;
        for(comb_index=0;comb_index<8;comb_index=comb_index+1)
            if(hold_keep[comb_index*2]&&hold_keep[comb_index*2+1])
                last_lane=comb_index[3:0];
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            hold_valid<=0;hold_last<=0;hold_data<=0;hold_keep<=0;lane<=0;error<=0;
        end else begin
            if(s_valid&&s_ready) begin
                hold_valid<=1;hold_last<=s_last;hold_data<=s_data;hold_keep<=s_keep;lane<=0;
                if(s_keep==0||(s_keep&(s_keep+1'b1))!=0) error<=1'b1;
                for(seq_index=0;seq_index<8;seq_index=seq_index+1)
                    if(s_keep[seq_index*2]!=s_keep[seq_index*2+1]) error<=1'b1;
            end else if(m_valid&&m_ready) begin
                if(lane==last_lane) hold_valid<=0;
                else lane<=lane+1'b1;
            end
        end
    end
endmodule
