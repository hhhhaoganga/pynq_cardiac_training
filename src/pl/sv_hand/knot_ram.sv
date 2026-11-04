`timescale 1ns/1ps
// Synchronous simple dual-port storage. No reset/clear on the RAM array.
// Read-during-write to the same address is not part of the core's contract.
module knot_ram #(parameter W=64, DEPTH=512, AW=$clog2(DEPTH)) (
    input wire clk, input wire we, input wire [AW-1:0] wa,
    input wire [W-1:0] wd, input wire [AW-1:0] ra,
    output reg [W-1:0] rd
);
    (* ram_style="block" *) reg [W-1:0] mem[0:DEPTH-1];
    always @(posedge clk) begin
        if(we) mem[wa]<=wd;
        rd<=mem[ra];
    end
endmodule
