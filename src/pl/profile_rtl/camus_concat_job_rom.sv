`timescale 1ns/1ps

// Fixed nearest/project + skip concat jobs for decoder ops 14, 18 and 22.
module camus_concat_job_rom (
    input logic [1:0] stage_index,
    output logic valid,
    output logic [8:0] low_width,
    output logic [8:0] low_height,
    output logic [5:0] project_channels,
    output logic [5:0] skip_channels,
    output logic [8:0] tile_low_rows,
    output logic signed [31:0] project_multiplier,
    output logic signed [6:0] project_shift,
    output logic signed [31:0] skip_multiplier,
    output logic signed [6:0] skip_shift
);
    `include "camus_concat_quant_desc.svh"

    always_comb begin
        valid=1'b1; low_width=0; low_height=0; project_channels=0;
        skip_channels=0; tile_low_rows=0; project_multiplier=0;
        project_shift=0; skip_multiplier=0; skip_shift=0;
        case(stage_index)
            0: begin
                low_width=32; low_height=32; project_channels=16; skip_channels=16;
                tile_low_rows=16;
                project_multiplier=CAMUS_CONCAT_S0_PROJECT_MULTIPLIER;
                project_shift=CAMUS_CONCAT_S0_PROJECT_SHIFT;
                skip_multiplier=CAMUS_CONCAT_S0_SKIP_MULTIPLIER;
                skip_shift=CAMUS_CONCAT_S0_SKIP_SHIFT;
            end
            1: begin
                low_width=64; low_height=64; project_channels=8; skip_channels=8;
                tile_low_rows=16;
                project_multiplier=CAMUS_CONCAT_S1_PROJECT_MULTIPLIER;
                project_shift=CAMUS_CONCAT_S1_PROJECT_SHIFT;
                skip_multiplier=CAMUS_CONCAT_S1_SKIP_MULTIPLIER;
                skip_shift=CAMUS_CONCAT_S1_SKIP_SHIFT;
            end
            2: begin
                low_width=128; low_height=128; project_channels=4; skip_channels=4;
                tile_low_rows=8;
                project_multiplier=CAMUS_CONCAT_S2_PROJECT_MULTIPLIER;
                project_shift=CAMUS_CONCAT_S2_PROJECT_SHIFT;
                skip_multiplier=CAMUS_CONCAT_S2_SKIP_MULTIPLIER;
                skip_shift=CAMUS_CONCAT_S2_SKIP_SHIFT;
            end
            default: valid=1'b0;
        endcase
    end
endmodule
