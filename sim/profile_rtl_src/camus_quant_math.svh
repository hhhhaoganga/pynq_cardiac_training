`ifndef CAMUS_QUANT_MATH_SVH
`define CAMUS_QUANT_MATH_SVH

function automatic signed [31:0] camus_round_shift(
    input signed [63:0] value,
    input integer shift
);
    reg signed [63:0] rounded;
    begin
        if (shift <= 0)
            camus_round_shift = value <<< (-shift);
        else begin
            rounded = value + (64'sd1 <<< (shift - 1));
            camus_round_shift = rounded >>> shift;
        end
    end
endfunction

function automatic signed [7:0] camus_sat_relu8(
    input signed [31:0] value,
    input logic relu_enable
);
    reg signed [31:0] clipped;
    begin
        clipped = value;
        if (relu_enable && clipped < 0)
            clipped = 0;
        if (clipped > 127)
            clipped = 127;
        else if (clipped < -128)
            clipped = -128;
        camus_sat_relu8 = clipped[7:0];
    end
endfunction

`endif
