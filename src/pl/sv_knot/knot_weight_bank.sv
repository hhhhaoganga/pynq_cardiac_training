`timescale 1ns/1ps
// Three physical 512x64 pages. Explicit paging avoids rounding a 1536-deep RAM
// up to 2048 entries and makes the read-select a fixed three-way mux.
(* keep_hierarchy="yes" *) module knot_weight_bank (
    input wire clk,we,input wire [10:0] wa,input wire [63:0] wd,
    input wire [10:0] ra,output wire [63:0] rd
);
    wire [63:0] q[0:2];reg [1:0] page;
    always @(posedge clk)page<=ra[10:9];
    for(genvar p=0;p<3;p=p+1)begin: bank
        knot_ram #(.DEPTH(512)) mem(clk,we&&(wa[10:9]==p),wa[8:0],wd,ra[8:0],q[p]);
    end
    assign rd=page==0?q[0]:page==1?q[1]:page==2?q[2]:64'b0;
endmodule
