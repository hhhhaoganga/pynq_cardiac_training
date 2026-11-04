`timescale 1ns/1ps
// Five taps x sixteen channels. Independent area experiment, no core integration.
module knot_dw_array(
    input wire clk,reset,valid,first,in_signed,
    input wire [639:0] window,
    input wire [383:0] previous,
    input wire [399:0] weights,
    input wire [8:0] address,
    output wire out_valid,
    output wire [383:0] result,
    output wire [8:0] out_address
);
    reg [3:0] v;
    reg [8:0] tags[0:3];
    always @(posedge clk)begin
        if(reset)v<=0;else v<={v[2:0],valid};
        tags[0]<=address;
        for(integer j=1;j<4;j=j+1)tags[j]<=tags[j-1];
    end
    assign out_valid=v[3];assign out_address=tags[3];
    for(genvar l=0;l<16;l=l+1)begin: lane
        (* use_dsp="no" *) reg signed [13:0] p[0:4];
        reg signed [15:0] s0,s1;
        reg signed [16:0] sum;
        reg signed [23:0] prev0,prev1,prev2,value;
        for(genvar t=0;t<5;t=t+1)begin: mult
            wire [7:0] b=window[128*t+8*l+:8];
            wire signed [8:0] a={in_signed&b[7],b};
            wire signed [4:0] w=weights[80*t+5*l+:5];
            always @(posedge clk)p[t]<=a*w;
        end
        always @(posedge clk)begin
            prev0<=first?24'sd0:$signed(previous[24*l+:24]);prev1<=prev0;prev2<=prev1;
            s0<=$signed(p[0])+$signed(p[1])+$signed(p[2]);
            s1<=$signed(p[3])+$signed(p[4]);
            sum<=$signed(s0)+$signed(s1);value<=prev2+sum;
        end
        assign result[24*l+:24]=value;
    end
endmodule
