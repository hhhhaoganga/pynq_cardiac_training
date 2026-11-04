`timescale 1ns/1ps

// Static convolution jobs for the frozen 19-layer Stream-Skip W4A8 graph.
// DDR feature rows are SIMD8 aligned; output_groups counts PE4 groups.
module camus_layer_job_rom (
    input  logic [4:0] layer_index,
    output logic valid,
    output logic decoder_engine,
    output logic [8:0] height,
    output logic [8:0] width,
    output logic [3:0] input_groups,
    output logic [3:0] output_groups,
    output logic [3:0] stored_output_groups,
    output logic kernel_3x3,
    output logic [9:0] weight_base,
    output logic [5:0] parameter_base,
    output logic [6:0] tokens_per_output_group,
    output logic relu_enable,
    output logic [8:0] tile_rows,
    output logic [19:0] input_row_words,
    output logic [31:0] input_row_bytes,
    output logic [31:0] input_tile_stride_bytes,
    output logic [31:0] output_row_bytes
);
    logic [4:0] padded_output_groups;

    always_comb begin
        valid = 1'b1;
        decoder_engine = 1'b0;
        height = 0; width = 0;
        input_groups = 0; output_groups = 0;
        kernel_3x3 = 1'b0;
        weight_base = 0; parameter_base = 0;
        tokens_per_output_group = 0;
        relu_enable = 1'b1;
        tile_rows = 0;
        case (layer_index)
            0:  begin height=256; width=256; input_groups=1;  output_groups=1; kernel_3x3=1; weight_base=0;   parameter_base=0;  tokens_per_output_group=9;  tile_rows=14; end
            1:  begin height=256; width=256; input_groups=1;  output_groups=1; kernel_3x3=1; weight_base=9;   parameter_base=1;  tokens_per_output_group=9;  tile_rows=14; end
            2:  begin height=128; width=128; input_groups=1;  output_groups=2; kernel_3x3=1; weight_base=18;  parameter_base=2;  tokens_per_output_group=9;  tile_rows=30; end
            3:  begin height=128; width=128; input_groups=1;  output_groups=2; kernel_3x3=1; weight_base=36;  parameter_base=4;  tokens_per_output_group=9;  tile_rows=30; end
            4:  begin height=64;  width=64;  input_groups=1;  output_groups=4; kernel_3x3=1; weight_base=54;  parameter_base=6;  tokens_per_output_group=9;  tile_rows=64; end
            5:  begin height=64;  width=64;  input_groups=2;  output_groups=4; kernel_3x3=1; weight_base=90;  parameter_base=10; tokens_per_output_group=18; tile_rows=30; end
            6:  begin height=32;  width=32;  input_groups=2;  output_groups=8; kernel_3x3=1; weight_base=162; parameter_base=14; tokens_per_output_group=18; tile_rows=32; end
            7:  begin height=32;  width=32;  input_groups=4;  output_groups=8; kernel_3x3=1; weight_base=306; parameter_base=22; tokens_per_output_group=36; tile_rows=32; end
            8:  begin decoder_engine=1; height=32;  width=32;  input_groups=12; output_groups=8; kernel_3x3=0; weight_base=594; parameter_base=30; tokens_per_output_group=12; tile_rows=10; end
            9:  begin decoder_engine=1; height=32;  width=32;  input_groups=4;  output_groups=4; kernel_3x3=0; weight_base=690; parameter_base=38; tokens_per_output_group=4;  tile_rows=32; end
            10: begin decoder_engine=1; height=64;  width=64;  input_groups=4;  output_groups=4; kernel_3x3=1; weight_base=706; parameter_base=42; tokens_per_output_group=36; tile_rows=14; end
            11: begin decoder_engine=1; height=64;  width=64;  input_groups=2;  output_groups=4; kernel_3x3=1; weight_base=850; parameter_base=46; tokens_per_output_group=18; tile_rows=30; end
            12: begin decoder_engine=1; height=64;  width=64;  input_groups=2;  output_groups=2; kernel_3x3=0; weight_base=922; parameter_base=50; tokens_per_output_group=2;  tile_rows=32; end
            13: begin decoder_engine=1; height=128; width=128; input_groups=2;  output_groups=2; kernel_3x3=1; weight_base=926; parameter_base=52; tokens_per_output_group=18; tile_rows=14; end
            14: begin decoder_engine=1; height=128; width=128; input_groups=1;  output_groups=2; kernel_3x3=1; weight_base=962; parameter_base=54; tokens_per_output_group=9;  tile_rows=30; end
            15: begin decoder_engine=1; height=128; width=128; input_groups=1;  output_groups=1; kernel_3x3=0; weight_base=980; parameter_base=56; tokens_per_output_group=1;  tile_rows=32; end
            16: begin decoder_engine=1; height=256; width=256; input_groups=1;  output_groups=1; kernel_3x3=1; weight_base=981; parameter_base=57; tokens_per_output_group=9;  tile_rows=14; end
            17: begin decoder_engine=1; height=256; width=256; input_groups=1;  output_groups=1; kernel_3x3=1; weight_base=990; parameter_base=58; tokens_per_output_group=9;  tile_rows=14; end
            18: begin decoder_engine=1; height=256; width=256; input_groups=1;  output_groups=1; kernel_3x3=0; weight_base=999; parameter_base=59; tokens_per_output_group=1;  tile_rows=16; relu_enable=1'b0; end
            default: begin valid=1'b0; relu_enable=1'b0; end
        endcase

        input_row_words = width * input_groups;
        input_row_bytes = input_row_words << 3;
        input_tile_stride_bytes = tile_rows * input_row_bytes;
        padded_output_groups = {1'b0, output_groups} + output_groups[0];
        stored_output_groups = padded_output_groups >> 1;
        output_row_bytes = width * padded_output_groups * 4;
    end
endmodule
