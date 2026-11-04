`timescale 1ns/1ps

// Fixed frame graph around the 19 convolution jobs and decoder SE stage. Buffer selectors are
// resolved by the frame scheduler from AXI-Lite base registers.
module camus_frame_op_rom (
    input  logic [4:0] op_index,
    output logic valid,
    output logic decoder_phase,
    output logic [2:0] op_kind,
    output logic [4:0] layer_index,
    output logic [2:0] source_sel,
    output logic [2:0] source_b_sel,
    output logic [2:0] dest_sel
);
    localparam logic [2:0] OP_CONV    = 3'd0;
    localparam logic [2:0] OP_POOL    = 3'd1;
    localparam logic [2:0] OP_HISTORY = 3'd2;
    localparam logic [2:0] OP_CONCAT  = 3'd3;
    localparam logic [2:0] OP_ARGMAX  = 3'd4;
    localparam logic [2:0] OP_LCC     = 3'd5;
    localparam logic [2:0] OP_SE      = 3'd6;

    localparam logic [2:0] BUF_INPUT   = 3'd0;
    localparam logic [2:0] BUF_SCRATCH0= 3'd1;
    localparam logic [2:0] BUF_SCRATCH1= 3'd2;
    localparam logic [2:0] BUF_SKIP1   = 3'd3;
    localparam logic [2:0] BUF_SKIP2   = 3'd4;
    localparam logic [2:0] BUF_SKIP3   = 3'd5;
    localparam logic [2:0] BUF_HISTORY = 3'd6;
    localparam logic [2:0] BUF_MASK    = 3'd7;

    task automatic set_conv(
        input logic [4:0] layer,
        input logic [2:0] src,
        input logic [2:0] dst
    );
        begin
            op_kind = OP_CONV;
            layer_index = layer;
            source_sel = src;
            dest_sel = dst;
        end
    endtask

    always_comb begin
        valid = 1'b1;
        decoder_phase = op_index >= 11;
        op_kind = OP_CONV;
        layer_index = 0;
        source_sel = BUF_INPUT;
        source_b_sel = BUF_INPUT;
        dest_sel = BUF_SCRATCH0;
        case (op_index)
            0:  set_conv(0,  BUF_INPUT,    BUF_SCRATCH0);
            1:  set_conv(1,  BUF_SCRATCH0, BUF_SKIP1);
            2:  begin op_kind=OP_POOL; layer_index=1; source_sel=BUF_SKIP1; dest_sel=BUF_SCRATCH0; end
            3:  set_conv(2,  BUF_SCRATCH0, BUF_SCRATCH1);
            4:  set_conv(3,  BUF_SCRATCH1, BUF_SKIP2);
            5:  begin op_kind=OP_POOL; layer_index=3; source_sel=BUF_SKIP2; dest_sel=BUF_SCRATCH0; end
            6:  set_conv(4,  BUF_SCRATCH0, BUF_SCRATCH1);
            7:  set_conv(5,  BUF_SCRATCH1, BUF_SKIP3);
            8:  begin op_kind=OP_POOL; layer_index=5; source_sel=BUF_SKIP3; dest_sel=BUF_SCRATCH0; end
            9:  set_conv(6,  BUF_SCRATCH0, BUF_SCRATCH1);
            10: set_conv(7,  BUF_SCRATCH1, BUF_HISTORY);
            11: begin op_kind=OP_HISTORY; layer_index=8; source_sel=BUF_HISTORY; dest_sel=BUF_SCRATCH0; end
            12: set_conv(8,  BUF_SCRATCH0, BUF_SCRATCH1);
            13: begin op_kind=OP_SE; layer_index=8; source_sel=BUF_SCRATCH1; dest_sel=BUF_SCRATCH0; end
            14: set_conv(9,  BUF_SCRATCH0, BUF_SCRATCH1);
            15: begin op_kind=OP_CONCAT; layer_index=10; source_sel=BUF_SCRATCH1; source_b_sel=BUF_SKIP3; dest_sel=BUF_SCRATCH0; end
            16: set_conv(10, BUF_SCRATCH0, BUF_SCRATCH1);
            17: set_conv(11, BUF_SCRATCH1, BUF_SCRATCH0);
            18: set_conv(12, BUF_SCRATCH0, BUF_SCRATCH1);
            19: begin op_kind=OP_CONCAT; layer_index=13; source_sel=BUF_SCRATCH1; source_b_sel=BUF_SKIP2; dest_sel=BUF_SCRATCH0; end
            20: set_conv(13, BUF_SCRATCH0, BUF_SCRATCH1);
            21: set_conv(14, BUF_SCRATCH1, BUF_SCRATCH0);
            22: set_conv(15, BUF_SCRATCH0, BUF_SCRATCH1);
            23: begin op_kind=OP_CONCAT; layer_index=16; source_sel=BUF_SCRATCH1; source_b_sel=BUF_SKIP1; dest_sel=BUF_SCRATCH0; end
            24: set_conv(16, BUF_SCRATCH0, BUF_SCRATCH1);
            25: set_conv(17, BUF_SCRATCH1, BUF_SCRATCH0);
            26: set_conv(18, BUF_SCRATCH0, BUF_SCRATCH1);
            27: begin op_kind=OP_ARGMAX; layer_index=18; source_sel=BUF_SCRATCH1; dest_sel=BUF_MASK; end
            28: begin op_kind=OP_LCC; layer_index=18; source_sel=BUF_MASK; source_b_sel=BUF_SCRATCH1; dest_sel=BUF_MASK; end
            default: begin valid=1'b0; decoder_phase=1'b0; end
        endcase
    end
endmodule
