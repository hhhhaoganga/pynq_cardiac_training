`timescale 1ns/1ps

module camus_frame_op_rom_tb;
    logic [4:0] op_index;
    logic valid, decoder_phase;
    logic [2:0] op_kind, source_sel, source_b_sel, dest_sel;
    logic [4:0] layer_index;
    integer i;
    integer conv_count, pool_count, history_count, se_count, concat_count, argmax_count, lcc_count;
    integer expected_layer;

    camus_frame_op_rom dut (.*);

    initial begin
        conv_count=0; pool_count=0; history_count=0; se_count=0; concat_count=0; argmax_count=0;
        lcc_count=0;
        expected_layer=0;
        for (i=0; i<29; i=i+1) begin
            op_index=i; #1;
            if (!valid)
                $fatal(1, "missing op %0d", i);
            if (decoder_phase != (i >= 11))
                $fatal(1, "phase mismatch op=%0d", i);
            case (op_kind)
                0: begin
                    if (layer_index != expected_layer)
                        $fatal(1, "layer order op=%0d got=%0d expected=%0d",
                               i, layer_index, expected_layer);
                    expected_layer=expected_layer+1;
                    conv_count=conv_count+1;
                end
                1: begin
                    if ((i == 2 && layer_index != 1)
                            || (i == 5 && layer_index != 3)
                            || (i == 8 && layer_index != 5))
                        $fatal(1, "pool context mismatch op=%0d layer=%0d", i, layer_index);
                    pool_count=pool_count+1;
                end
                2: begin
                    if (layer_index != 8)
                        $fatal(1, "history context mismatch layer=%0d", layer_index);
                    history_count=history_count+1;
                end
                3: begin
                    if ((i == 15 && layer_index != 10)
                            || (i == 19 && layer_index != 13)
                            || (i == 23 && layer_index != 16))
                        $fatal(1, "concat context mismatch op=%0d layer=%0d", i, layer_index);
                    concat_count=concat_count+1;
                end
                4: begin
                    if (layer_index != 18)
                        $fatal(1, "argmax context mismatch layer=%0d", layer_index);
                    argmax_count=argmax_count+1;
                end
                5: begin
                    if (i != 28 || layer_index != 18 || source_sel != 7
                            || source_b_sel != 2 || dest_sel != 7)
                        $fatal(1, "lcc context mismatch op=%0d layer=%0d src=%0d scratch=%0d dst=%0d",
                               i, layer_index, source_sel, source_b_sel, dest_sel);
                    lcc_count=lcc_count+1;
                end
                6: begin
                    if (i != 13 || layer_index != 8 || source_sel != 2 || dest_sel != 1)
                        $fatal(1, "se context mismatch op=%0d layer=%0d src=%0d dst=%0d",
                               i, layer_index, source_sel, dest_sel);
                    se_count=se_count+1;
                end
                default: $fatal(1, "bad kind op=%0d", i);
            endcase
        end
        op_index=31; #1;
        if (valid || conv_count!=19 || pool_count!=3 || history_count!=1
                || se_count!=1 || concat_count!=3 || argmax_count!=1 || lcc_count!=1)
            $fatal(1, "graph summary conv=%0d pool=%0d history=%0d se=%0d concat=%0d argmax=%0d lcc=%0d",
                   conv_count,pool_count,history_count,se_count,concat_count,argmax_count,lcc_count);
        $display("PASS camus_frame_op_rom ops=29 conv=19 aux=10");
        $finish;
    end
endmodule
