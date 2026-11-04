`ifndef CAMUS_STREAM_ROM_DESC_SVH
`define CAMUS_STREAM_ROM_DESC_SVH

localparam integer CAMUS_STREAM_ROM_PE = 4;
localparam integer CAMUS_STREAM_ROM_SIMD = 8;
localparam integer CAMUS_STREAM_WEIGHT_WORDS = 1000;
localparam integer CAMUS_STREAM_PARAMETER_GROUPS = 60;

// 00: enc1.0
localparam integer CAMUS_ROM_L00_WEIGHT_OFFSET = 0;
localparam integer CAMUS_ROM_L00_WEIGHT_WORDS = 9;
localparam integer CAMUS_ROM_L00_PARAM_OFFSET = 0;
localparam logic signed [31:0] CAMUS_ROM_L00_INPUT_MULTIPLIER = 32'sd1073741761;
localparam logic signed [6:0] CAMUS_ROM_L00_INPUT_SHIFT = 7'sd30;
localparam integer CAMUS_ROM_L00_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L00_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L00_TOKENS = 9;
localparam integer CAMUS_ROM_L00_RELU = 1;

// 01: enc1.3
localparam integer CAMUS_ROM_L01_WEIGHT_OFFSET = 9;
localparam integer CAMUS_ROM_L01_WEIGHT_WORDS = 9;
localparam integer CAMUS_ROM_L01_PARAM_OFFSET = 1;
localparam logic signed [31:0] CAMUS_ROM_L01_INPUT_MULTIPLIER = 32'sd550873978;
localparam logic signed [6:0] CAMUS_ROM_L01_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L01_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L01_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L01_TOKENS = 9;
localparam integer CAMUS_ROM_L01_RELU = 1;

// 02: enc2.0
localparam integer CAMUS_ROM_L02_WEIGHT_OFFSET = 18;
localparam integer CAMUS_ROM_L02_WEIGHT_WORDS = 18;
localparam integer CAMUS_ROM_L02_PARAM_OFFSET = 2;
localparam logic signed [31:0] CAMUS_ROM_L02_INPUT_MULTIPLIER = 32'sd547515089;
localparam logic signed [6:0] CAMUS_ROM_L02_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L02_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L02_OUTPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L02_TOKENS = 9;
localparam integer CAMUS_ROM_L02_RELU = 1;

// 03: enc2.3
localparam integer CAMUS_ROM_L03_WEIGHT_OFFSET = 36;
localparam integer CAMUS_ROM_L03_WEIGHT_WORDS = 18;
localparam integer CAMUS_ROM_L03_PARAM_OFFSET = 4;
localparam logic signed [31:0] CAMUS_ROM_L03_INPUT_MULTIPLIER = 32'sd564247043;
localparam logic signed [6:0] CAMUS_ROM_L03_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L03_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L03_OUTPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L03_TOKENS = 9;
localparam integer CAMUS_ROM_L03_RELU = 1;

// 04: enc3.0
localparam integer CAMUS_ROM_L04_WEIGHT_OFFSET = 54;
localparam integer CAMUS_ROM_L04_WEIGHT_WORDS = 36;
localparam integer CAMUS_ROM_L04_PARAM_OFFSET = 6;
localparam logic signed [31:0] CAMUS_ROM_L04_INPUT_MULTIPLIER = 32'sd545975753;
localparam logic signed [6:0] CAMUS_ROM_L04_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L04_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L04_OUTPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L04_TOKENS = 9;
localparam integer CAMUS_ROM_L04_RELU = 1;

// 05: enc3.3
localparam integer CAMUS_ROM_L05_WEIGHT_OFFSET = 90;
localparam integer CAMUS_ROM_L05_WEIGHT_WORDS = 72;
localparam integer CAMUS_ROM_L05_PARAM_OFFSET = 10;
localparam logic signed [31:0] CAMUS_ROM_L05_INPUT_MULTIPLIER = 32'sd550059459;
localparam logic signed [6:0] CAMUS_ROM_L05_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L05_INPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L05_OUTPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L05_TOKENS = 18;
localparam integer CAMUS_ROM_L05_RELU = 1;

// 06: enc4.0
localparam integer CAMUS_ROM_L06_WEIGHT_OFFSET = 162;
localparam integer CAMUS_ROM_L06_WEIGHT_WORDS = 144;
localparam integer CAMUS_ROM_L06_PARAM_OFFSET = 14;
localparam logic signed [31:0] CAMUS_ROM_L06_INPUT_MULTIPLIER = 32'sd555363151;
localparam logic signed [6:0] CAMUS_ROM_L06_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L06_INPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L06_OUTPUT_GROUPS = 8;
localparam integer CAMUS_ROM_L06_TOKENS = 18;
localparam integer CAMUS_ROM_L06_RELU = 1;

// 07: enc4.3
localparam integer CAMUS_ROM_L07_WEIGHT_OFFSET = 306;
localparam integer CAMUS_ROM_L07_WEIGHT_WORDS = 288;
localparam integer CAMUS_ROM_L07_PARAM_OFFSET = 22;
localparam logic signed [31:0] CAMUS_ROM_L07_INPUT_MULTIPLIER = 32'sd551208532;
localparam logic signed [6:0] CAMUS_ROM_L07_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L07_INPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L07_OUTPUT_GROUPS = 8;
localparam integer CAMUS_ROM_L07_TOKENS = 36;
localparam integer CAMUS_ROM_L07_RELU = 1;

// 08: temporal.0
localparam integer CAMUS_ROM_L08_WEIGHT_OFFSET = 594;
localparam integer CAMUS_ROM_L08_WEIGHT_WORDS = 96;
localparam integer CAMUS_ROM_L08_PARAM_OFFSET = 30;
localparam logic signed [31:0] CAMUS_ROM_L08_INPUT_MULTIPLIER = 32'sd545486972;
localparam logic signed [6:0] CAMUS_ROM_L08_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L08_INPUT_GROUPS = 12;
localparam integer CAMUS_ROM_L08_OUTPUT_GROUPS = 8;
localparam integer CAMUS_ROM_L08_TOKENS = 12;
localparam integer CAMUS_ROM_L08_RELU = 1;

// 09: dec3.project.0
localparam integer CAMUS_ROM_L09_WEIGHT_OFFSET = 690;
localparam integer CAMUS_ROM_L09_WEIGHT_WORDS = 16;
localparam integer CAMUS_ROM_L09_PARAM_OFFSET = 38;
localparam logic signed [31:0] CAMUS_ROM_L09_INPUT_MULTIPLIER = 32'sd536870912;
localparam logic signed [6:0] CAMUS_ROM_L09_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L09_INPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L09_OUTPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L09_TOKENS = 4;
localparam integer CAMUS_ROM_L09_RELU = 1;

// 10: dec3.refine.0
localparam integer CAMUS_ROM_L10_WEIGHT_OFFSET = 706;
localparam integer CAMUS_ROM_L10_WEIGHT_WORDS = 144;
localparam integer CAMUS_ROM_L10_PARAM_OFFSET = 42;
localparam logic signed [31:0] CAMUS_ROM_L10_INPUT_MULTIPLIER = 32'sd536870912;
localparam logic signed [6:0] CAMUS_ROM_L10_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L10_INPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L10_OUTPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L10_TOKENS = 36;
localparam integer CAMUS_ROM_L10_RELU = 1;

// 11: dec3.refine.3
localparam integer CAMUS_ROM_L11_WEIGHT_OFFSET = 850;
localparam integer CAMUS_ROM_L11_WEIGHT_WORDS = 72;
localparam integer CAMUS_ROM_L11_PARAM_OFFSET = 46;
localparam logic signed [31:0] CAMUS_ROM_L11_INPUT_MULTIPLIER = 32'sd557068373;
localparam logic signed [6:0] CAMUS_ROM_L11_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L11_INPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L11_OUTPUT_GROUPS = 4;
localparam integer CAMUS_ROM_L11_TOKENS = 18;
localparam integer CAMUS_ROM_L11_RELU = 1;

// 12: dec2.project.0
localparam integer CAMUS_ROM_L12_WEIGHT_OFFSET = 922;
localparam integer CAMUS_ROM_L12_WEIGHT_WORDS = 4;
localparam integer CAMUS_ROM_L12_PARAM_OFFSET = 50;
localparam logic signed [31:0] CAMUS_ROM_L12_INPUT_MULTIPLIER = 32'sd552933326;
localparam logic signed [6:0] CAMUS_ROM_L12_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L12_INPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L12_OUTPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L12_TOKENS = 2;
localparam integer CAMUS_ROM_L12_RELU = 1;

// 13: dec2.refine.0
localparam integer CAMUS_ROM_L13_WEIGHT_OFFSET = 926;
localparam integer CAMUS_ROM_L13_WEIGHT_WORDS = 36;
localparam integer CAMUS_ROM_L13_PARAM_OFFSET = 52;
localparam logic signed [31:0] CAMUS_ROM_L13_INPUT_MULTIPLIER = 32'sd536870912;
localparam logic signed [6:0] CAMUS_ROM_L13_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L13_INPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L13_OUTPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L13_TOKENS = 18;
localparam integer CAMUS_ROM_L13_RELU = 1;

// 14: dec2.refine.3
localparam integer CAMUS_ROM_L14_WEIGHT_OFFSET = 962;
localparam integer CAMUS_ROM_L14_WEIGHT_WORDS = 18;
localparam integer CAMUS_ROM_L14_PARAM_OFFSET = 54;
localparam logic signed [31:0] CAMUS_ROM_L14_INPUT_MULTIPLIER = 32'sd544811501;
localparam logic signed [6:0] CAMUS_ROM_L14_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L14_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L14_OUTPUT_GROUPS = 2;
localparam integer CAMUS_ROM_L14_TOKENS = 9;
localparam integer CAMUS_ROM_L14_RELU = 1;

// 15: dec1.project.0
localparam integer CAMUS_ROM_L15_WEIGHT_OFFSET = 980;
localparam integer CAMUS_ROM_L15_WEIGHT_WORDS = 1;
localparam integer CAMUS_ROM_L15_PARAM_OFFSET = 56;
localparam logic signed [31:0] CAMUS_ROM_L15_INPUT_MULTIPLIER = 32'sd545559652;
localparam logic signed [6:0] CAMUS_ROM_L15_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L15_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L15_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L15_TOKENS = 1;
localparam integer CAMUS_ROM_L15_RELU = 1;

// 16: dec1.refine.0
localparam integer CAMUS_ROM_L16_WEIGHT_OFFSET = 981;
localparam integer CAMUS_ROM_L16_WEIGHT_WORDS = 9;
localparam integer CAMUS_ROM_L16_PARAM_OFFSET = 57;
localparam logic signed [31:0] CAMUS_ROM_L16_INPUT_MULTIPLIER = 32'sd536870912;
localparam logic signed [6:0] CAMUS_ROM_L16_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L16_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L16_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L16_TOKENS = 9;
localparam integer CAMUS_ROM_L16_RELU = 1;

// 17: dec1.refine.3
localparam integer CAMUS_ROM_L17_WEIGHT_OFFSET = 990;
localparam integer CAMUS_ROM_L17_WEIGHT_WORDS = 9;
localparam integer CAMUS_ROM_L17_PARAM_OFFSET = 58;
localparam logic signed [31:0] CAMUS_ROM_L17_INPUT_MULTIPLIER = 32'sd544693271;
localparam logic signed [6:0] CAMUS_ROM_L17_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L17_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L17_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L17_TOKENS = 9;
localparam integer CAMUS_ROM_L17_RELU = 1;

// 18: head
localparam integer CAMUS_ROM_L18_WEIGHT_OFFSET = 999;
localparam integer CAMUS_ROM_L18_WEIGHT_WORDS = 1;
localparam integer CAMUS_ROM_L18_PARAM_OFFSET = 59;
localparam logic signed [31:0] CAMUS_ROM_L18_INPUT_MULTIPLIER = 32'sd544160918;
localparam logic signed [6:0] CAMUS_ROM_L18_INPUT_SHIFT = 7'sd29;
localparam integer CAMUS_ROM_L18_INPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L18_OUTPUT_GROUPS = 1;
localparam integer CAMUS_ROM_L18_TOKENS = 1;
localparam integer CAMUS_ROM_L18_RELU = 0;

`endif
