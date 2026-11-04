`timescale 1ns/1ps
// Eight shared requantization lanes. Bias addition wraps to 24 bits exactly as
// the reviewed integer kernel. Signed rounding is add-half then arithmetic shift.
module knot_quant8 (
    input wire clk, reset, valid,
    input wire [191:0] accum, bias,
    input wire [255:0] mult,
    input wire [47:0] shift,
    input wire [63:0] residual,
    input wire residual_enable, residual_signed,
    input wire signed [31:0] ma, mb,
    input wire signed [15:0] lo, hi, alo, ahi,
    input wire [15:0] tag,
    output wire out_valid, output wire [63:0] result,
    output wire [15:0] out_tag
);
    reg [6:0] v;
    reg [15:0] tags[0:6];
    always @(posedge clk) begin
        if(reset) v<=0; else v<={v[5:0],valid};
        tags[0]<=tag;
        for(integer i=1;i<7;i=i+1) tags[i]<=tags[i-1];
    end
    assign out_valid=v[6]; assign out_tag=tags[6];
    // Configuration stays fixed until this pipeline has drained.
    for(genvar l=0;l<8;l=l+1) begin: lane
        reg signed [23:0] a0;
        reg signed [31:0] m0;
        reg [5:0] sh0,sh1;
        (* use_dsp="yes" *) reg signed [55:0] prod1;
        reg signed [55:0] scaled2;
        reg signed [9:0] clamped3;
        reg signed [9:0] r0,r1,r2,r3;
        (* use_dsp="yes" *) reg signed [41:0] ym4,rm4;
        reg signed [47:0] added5;
        reg [7:0] out6;
        reg signed [9:0] bypass4,bypass5;
        always @(posedge clk) begin
            a0 <= $signed(accum[l*24+:24])+$signed(bias[l*24+:24]);
            m0 <= $signed(mult[l*32+:32]); sh0<=shift[l*6+:6];
            r0<=residual_signed ? $signed({{2{residual[l*8+7]}},residual[l*8+:8]}) : $signed({2'b0,residual[l*8+:8]});
            prod1<=a0*m0; sh1<=sh0; r1<=r0;
            scaled2<=(prod1+(56'sd1<<(sh1-1)))>>>sh1; r2<=r1;
            clamped3<=scaled2<lo ? lo : scaled2>hi ? hi : scaled2; r3<=r2;
            ym4<=clamped3*ma; rm4<=r3*mb; bypass4<=clamped3;
            added5<=($signed(ym4)+$signed(rm4)+48'sd524288)>>>20; bypass5<=bypass4;
            if(!residual_enable) out6<=bypass5;
            else out6<=added5<alo ? alo : added5>ahi ? ahi : added5;
        end
        assign result[l*8+:8]=out6;
    end
endmodule
