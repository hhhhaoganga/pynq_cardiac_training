`ifndef CAMUS_CONCAT_QUANT_DESC_SVH
`define CAMUS_CONCAT_QUANT_DESC_SVH

// concat stage 0: dec3.project.0 + enc3.3 -> dec3.refine.0
localparam logic signed [31:0] CAMUS_CONCAT_S0_PROJECT_MULTIPLIER = 32'sd548571000;
localparam logic signed [6:0] CAMUS_CONCAT_S0_PROJECT_SHIFT = 7'sd29;
localparam logic signed [31:0] CAMUS_CONCAT_S0_SKIP_MULTIPLIER = 32'sd813115001;
localparam logic signed [6:0] CAMUS_CONCAT_S0_SKIP_SHIFT = 7'sd30;

// concat stage 1: dec2.project.0 + enc2.3 -> dec2.refine.0
localparam logic signed [31:0] CAMUS_CONCAT_S1_PROJECT_MULTIPLIER = 32'sd548148269;
localparam logic signed [6:0] CAMUS_CONCAT_S1_PROJECT_SHIFT = 7'sd29;
localparam logic signed [31:0] CAMUS_CONCAT_S1_SKIP_MULTIPLIER = 32'sd1027618255;
localparam logic signed [6:0] CAMUS_CONCAT_S1_SKIP_SHIFT = 7'sd30;

// concat stage 2: dec1.project.0 + enc1.3 -> dec1.refine.0
localparam logic signed [31:0] CAMUS_CONCAT_S2_PROJECT_MULTIPLIER = 32'sd1038540936;
localparam logic signed [6:0] CAMUS_CONCAT_S2_PROJECT_SHIFT = 7'sd30;
localparam logic signed [31:0] CAMUS_CONCAT_S2_SKIP_MULTIPLIER = 32'sd547162870;
localparam logic signed [6:0] CAMUS_CONCAT_S2_SKIP_SHIFT = 7'sd29;

`endif
