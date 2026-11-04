`timescale 1ns/1ps
module tb_quant;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,valid=0,re,rs;
    reg [191:0] a,b;reg [255:0] m;reg [47:0] sh;reg [63:0] r,expected;
    reg signed [31:0] ma,mb;
    reg signed [15:0] lo,hi,alo,ahi;
    reg [15:0] tag=0;
    wire ov;wire [63:0] result;wire [15:0] ot;
    integer f,n,tests=0;
    knot_quant8 dut(clk,reset,valid,a,b,m,sh,r,re,rs,ma,mb,lo,hi,alo,ahi,tag,ov,result,ot);
    initial begin
        f=$fopen("fixture/quant.txt","r");if(!f)$fatal(1,"Missing oracle vectors");
        repeat(5)@(negedge clk);reset=0;
        while(tests<512)begin
            n=$fscanf(f,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",a,b,m,sh,r,re,rs,ma,mb,lo,hi,alo,ahi,expected);
            if(n!=14)$fatal(1,"Malformed oracle vector");
            tag=tests;valid=1;@(negedge clk);valid=0;
            wait(ov);@(negedge clk);
            if(result!==expected||ot!=tag)$fatal(1,"QUANT mismatch case=%0d actual=%h expected=%h",tests,result,expected);
            tests=tests+1;@(negedge clk);
        end
        if(tests!=512)$fatal(1,"Missing cases");
        $display("SV_QUANT_EDGE_PASS cases=%0d lanes=%0d",tests,tests*8);$finish;
    end
endmodule
