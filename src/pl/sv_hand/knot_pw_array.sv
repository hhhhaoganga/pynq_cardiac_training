`timescale 1ns/1ps
// Isolated resource/timing experiment. Not integrated into the released knot core.
module knot_pw_array #(parameter integer NI=8)(
    input wire clk,reset,valid,first,last,high_plane,in_signed,
    input wire [1:0] chunk,
    input wire [127:0] activation,
    input wire [16*NI*5-1:0] weight_tile,
    input wire [31:0] tag,
    output wire out_valid, output wire [383:0] result,
    output wire [31:0] out_tag
);
    localparam integer LEAVES=NI==4?4:8;
    localparam integer LEVELS=NI==4?2:3;
    localparam integer LATENCY=LEVELS+3;
    reg [LATENCY-1:0] v,f,e,h;
    reg [31:0] tags[0:LATENCY-1];
    reg signed [8:0] a[0:NI-1];
    reg [16*NI*5-1:0] weights;
    always @(posedge clk)begin
        weights<=weight_tile;
        if(reset)begin v<=0;f<=0;e<=0;h<=0;end
        else begin v<={v[LATENCY-2:0],valid};f<={f[LATENCY-2:0],first};
            e<={e[LATENCY-2:0],last};h<={h[LATENCY-2:0],high_plane};end
        tags[0]<=tag;
        for(integer j=1;j<LATENCY;j=j+1)tags[j]<=tags[j-1];
    end
    for(genvar i=0;i<NI;i=i+1)begin: input_register
        wire [7:0] c0=activation[8*i+:8];
        wire [7:0] c1,c2,c3;
        if(NI+i<16) assign c1=activation[8*(NI+i)+:8]; else assign c1=0;
        if(2*NI+i<16) assign c2=activation[8*(2*NI+i)+:8]; else assign c2=0;
        if(3*NI+i<16) assign c3=activation[8*(3*NI+i)+:8]; else assign c3=0;
        wire [7:0] byte_value=chunk==0?c0:chunk==1?c1:chunk==2?c2:c3;
        always @(posedge clk)a[i]<=$signed({in_signed&byte_value[7],byte_value});
    end
    assign out_valid=v[LATENCY-1]&e[LATENCY-1];
    assign out_tag=tags[LATENCY-1];
    for(genvar o=0;o<16;o=o+1)begin: pe
        (* use_dsp="no" *) reg signed [13:0] products[0:LEAVES-1];
        for(genvar i=0;i<LEAVES;i=i+1)begin: mult
            if(i<NI)begin
                wire signed [4:0] w=weights[5*(o*NI+i)+:5];
                always @(posedge clk)products[i]<=a[i]*w;
            end else always @(posedge clk)products[i]<=0;
        end
        for(genvar level=1;level<=LEVELS;level=level+1)begin: tree
            reg signed [13+level:0] sums[0:(LEAVES>>level)-1];
            for(genvar j=0;j<(LEAVES>>level);j=j+1)begin: add
                if(level==1)always @(posedge clk)sums[j]<=$signed(products[2*j])+$signed(products[2*j+1]);
                else always @(posedge clk)sums[j]<=$signed(tree[level-1].sums[2*j])+$signed(tree[level-1].sums[2*j+1]);
            end
        end
        reg signed [23:0] acc;
        wire signed [23:0] sum_ext=tree[LEVELS].sums[0];
        always @(posedge clk)if(v[LATENCY-2])
            acc<=(f[LATENCY-2]?24'sd0:acc)+(h[LATENCY-2]?(sum_ext<<<4):sum_ext);
        assign result[24*o+:24]=acc;
    end
endmodule
