`timescale 1ns/1ps
// One physical array: 16 output lanes x 4 input lanes, II=1.
// Tokens and reset-of-accumulator travel with the data, independently of RAM stalls.
module knot_pw_array (
    input wire clk, reset, valid, first, last, high_plane, in_signed,
    input wire [1:0] quarter,
    input wire [127:0] activation,
    input wire [319:0] weight_tile,
    input wire [31:0] tag,
    output wire out_valid, output wire [383:0] result,
    output wire [31:0] out_tag
);
    reg [4:0] v,f,e,h;
    reg signed [8:0] input_lane[0:3];
    reg [319:0] weights;
    for(genvar i=0;i<4;i=i+1)begin: input_register
        wire [7:0] b=activation[8*(quarter*4+i)+:8];
        always @(posedge clk)input_lane[i]<=$signed({in_signed&b[7],b});
    end
    always @(posedge clk)weights<=weight_tile;
    reg [31:0] tags[0:4];
    always @(posedge clk) begin
        if(reset) begin v<=0;f<=0;e<=0;h<=0;end
        else begin v<={v[3:0],valid};f<={f[3:0],first};e<={e[3:0],last};h<={h[3:0],high_plane};end
        tags[0]<=tag;
        for(integer j=1;j<5;j=j+1) tags[j]<=tags[j-1];
    end
    assign out_valid=v[4]&e[4]; assign out_tag=tags[4];
    for(genvar o=0;o<16;o=o+1) begin: pe
        (* use_dsp="no" *) reg signed [13:0] p0[0:3];
        reg signed [14:0] s1[0:1];
        reg signed [15:0] s2;
        reg signed [23:0] acc;
        wire signed [23:0] sx={{8{s2[15]}},s2};
        for(genvar i=0;i<4;i=i+1) begin: mul
            wire signed [4:0] w=weights[5*(o*4+i)+:5];
            always @(posedge clk) p0[i]<=input_lane[i]*w;
        end
        always @(posedge clk) begin
            s1[0]<=$signed(p0[0])+$signed(p0[1]);
            s1[1]<=$signed(p0[2])+$signed(p0[3]);
            s2<=$signed(s1[0])+$signed(s1[1]);
            if(v[3]) acc<=(f[3]?24'sd0:acc)+(h[3]?(sx<<<4):sx);
        end
        assign result[o*24+:24]=acc;
    end
endmodule
