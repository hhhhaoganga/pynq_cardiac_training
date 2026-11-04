`timescale 1ns/1ps
module knot_dw_array (
    input wire clk,reset,valid,first,in_signed,
    input wire [383:0] window,previous,
    input wire [239:0] weights,
    input wire [8:0] address,
    output wire out_valid, output wire [383:0] result,
    output wire [8:0] out_address
);
    reg [2:0] v;
    reg [8:0] tags[0:2];
    always @(posedge clk) begin
        if(reset) v<=0; else v<={v[1:0],valid};
        tags[0]<=address;tags[1]<=tags[0];tags[2]<=tags[1];
    end
    assign out_valid=v[2];assign out_address=tags[2];
    for(genvar l=0;l<16;l=l+1) begin: lane
        (* use_dsp="no" *) reg signed [13:0] p[0:2];
        reg signed [15:0] sum;
        reg signed [23:0] prev0,prev1,value;
        for(genvar t=0;t<3;t=t+1) begin: mul
            wire [7:0] b=window[t*128+l*8+:8];
            wire signed [8:0] a={in_signed&b[7],b};
            wire signed [4:0] w=weights[(t*16+l)*5+:5];
            always @(posedge clk) p[t]<=a*w;
        end
        always @(posedge clk) begin
            prev0<=first?24'sd0:$signed(previous[l*24+:24]);prev1<=prev0;
            sum<=$signed(p[0])+$signed(p[1])+$signed(p[2]);
            value<=prev1+sum;
        end
        assign result[l*24+:24]=value;
    end
endmodule
