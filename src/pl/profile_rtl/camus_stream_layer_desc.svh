`ifndef CAMUS_STREAM_LAYER_DESC_SVH
`define CAMUS_STREAM_LAYER_DESC_SVH

localparam integer CAMUS_STREAM_LAYER_COUNT = 19;
localparam integer CAMUS_STREAM_WEIGHT_BYTES = 15578;

// name, engine(0=encoder/1=decoder), H, W, IC, OC, K, W4 byte offset, W4 bytes
// 00: enc1.0
localparam integer CAMUS_L00_ENGINE = 0;
localparam integer CAMUS_L00_H = 256;
localparam integer CAMUS_L00_W = 256;
localparam integer CAMUS_L00_IC = 1;
localparam integer CAMUS_L00_OC = 4;
localparam integer CAMUS_L00_K = 3;
localparam integer CAMUS_L00_WEIGHT_OFFSET = 0;
localparam integer CAMUS_L00_WEIGHT_BYTES = 18;

// 01: enc1.3
localparam integer CAMUS_L01_ENGINE = 0;
localparam integer CAMUS_L01_H = 256;
localparam integer CAMUS_L01_W = 256;
localparam integer CAMUS_L01_IC = 4;
localparam integer CAMUS_L01_OC = 4;
localparam integer CAMUS_L01_K = 3;
localparam integer CAMUS_L01_WEIGHT_OFFSET = 18;
localparam integer CAMUS_L01_WEIGHT_BYTES = 72;

// 02: enc2.0
localparam integer CAMUS_L02_ENGINE = 0;
localparam integer CAMUS_L02_H = 128;
localparam integer CAMUS_L02_W = 128;
localparam integer CAMUS_L02_IC = 4;
localparam integer CAMUS_L02_OC = 8;
localparam integer CAMUS_L02_K = 3;
localparam integer CAMUS_L02_WEIGHT_OFFSET = 90;
localparam integer CAMUS_L02_WEIGHT_BYTES = 144;

// 03: enc2.3
localparam integer CAMUS_L03_ENGINE = 0;
localparam integer CAMUS_L03_H = 128;
localparam integer CAMUS_L03_W = 128;
localparam integer CAMUS_L03_IC = 8;
localparam integer CAMUS_L03_OC = 8;
localparam integer CAMUS_L03_K = 3;
localparam integer CAMUS_L03_WEIGHT_OFFSET = 234;
localparam integer CAMUS_L03_WEIGHT_BYTES = 288;

// 04: enc3.0
localparam integer CAMUS_L04_ENGINE = 0;
localparam integer CAMUS_L04_H = 64;
localparam integer CAMUS_L04_W = 64;
localparam integer CAMUS_L04_IC = 8;
localparam integer CAMUS_L04_OC = 16;
localparam integer CAMUS_L04_K = 3;
localparam integer CAMUS_L04_WEIGHT_OFFSET = 522;
localparam integer CAMUS_L04_WEIGHT_BYTES = 576;

// 05: enc3.3
localparam integer CAMUS_L05_ENGINE = 0;
localparam integer CAMUS_L05_H = 64;
localparam integer CAMUS_L05_W = 64;
localparam integer CAMUS_L05_IC = 16;
localparam integer CAMUS_L05_OC = 16;
localparam integer CAMUS_L05_K = 3;
localparam integer CAMUS_L05_WEIGHT_OFFSET = 1098;
localparam integer CAMUS_L05_WEIGHT_BYTES = 1152;

// 06: enc4.0
localparam integer CAMUS_L06_ENGINE = 0;
localparam integer CAMUS_L06_H = 32;
localparam integer CAMUS_L06_W = 32;
localparam integer CAMUS_L06_IC = 16;
localparam integer CAMUS_L06_OC = 32;
localparam integer CAMUS_L06_K = 3;
localparam integer CAMUS_L06_WEIGHT_OFFSET = 2250;
localparam integer CAMUS_L06_WEIGHT_BYTES = 2304;

// 07: enc4.3
localparam integer CAMUS_L07_ENGINE = 0;
localparam integer CAMUS_L07_H = 32;
localparam integer CAMUS_L07_W = 32;
localparam integer CAMUS_L07_IC = 32;
localparam integer CAMUS_L07_OC = 32;
localparam integer CAMUS_L07_K = 3;
localparam integer CAMUS_L07_WEIGHT_OFFSET = 4554;
localparam integer CAMUS_L07_WEIGHT_BYTES = 4608;

// 08: temporal.0
localparam integer CAMUS_L08_ENGINE = 1;
localparam integer CAMUS_L08_H = 32;
localparam integer CAMUS_L08_W = 32;
localparam integer CAMUS_L08_IC = 96;
localparam integer CAMUS_L08_OC = 32;
localparam integer CAMUS_L08_K = 1;
localparam integer CAMUS_L08_WEIGHT_OFFSET = 9162;
localparam integer CAMUS_L08_WEIGHT_BYTES = 1536;

// 09: dec3.project.0
localparam integer CAMUS_L09_ENGINE = 1;
localparam integer CAMUS_L09_H = 32;
localparam integer CAMUS_L09_W = 32;
localparam integer CAMUS_L09_IC = 32;
localparam integer CAMUS_L09_OC = 16;
localparam integer CAMUS_L09_K = 1;
localparam integer CAMUS_L09_WEIGHT_OFFSET = 10698;
localparam integer CAMUS_L09_WEIGHT_BYTES = 256;

// 10: dec3.refine.0
localparam integer CAMUS_L10_ENGINE = 1;
localparam integer CAMUS_L10_H = 64;
localparam integer CAMUS_L10_W = 64;
localparam integer CAMUS_L10_IC = 32;
localparam integer CAMUS_L10_OC = 16;
localparam integer CAMUS_L10_K = 3;
localparam integer CAMUS_L10_WEIGHT_OFFSET = 10954;
localparam integer CAMUS_L10_WEIGHT_BYTES = 2304;

// 11: dec3.refine.3
localparam integer CAMUS_L11_ENGINE = 1;
localparam integer CAMUS_L11_H = 64;
localparam integer CAMUS_L11_W = 64;
localparam integer CAMUS_L11_IC = 16;
localparam integer CAMUS_L11_OC = 16;
localparam integer CAMUS_L11_K = 3;
localparam integer CAMUS_L11_WEIGHT_OFFSET = 13258;
localparam integer CAMUS_L11_WEIGHT_BYTES = 1152;

// 12: dec2.project.0
localparam integer CAMUS_L12_ENGINE = 1;
localparam integer CAMUS_L12_H = 64;
localparam integer CAMUS_L12_W = 64;
localparam integer CAMUS_L12_IC = 16;
localparam integer CAMUS_L12_OC = 8;
localparam integer CAMUS_L12_K = 1;
localparam integer CAMUS_L12_WEIGHT_OFFSET = 14410;
localparam integer CAMUS_L12_WEIGHT_BYTES = 64;

// 13: dec2.refine.0
localparam integer CAMUS_L13_ENGINE = 1;
localparam integer CAMUS_L13_H = 128;
localparam integer CAMUS_L13_W = 128;
localparam integer CAMUS_L13_IC = 16;
localparam integer CAMUS_L13_OC = 8;
localparam integer CAMUS_L13_K = 3;
localparam integer CAMUS_L13_WEIGHT_OFFSET = 14474;
localparam integer CAMUS_L13_WEIGHT_BYTES = 576;

// 14: dec2.refine.3
localparam integer CAMUS_L14_ENGINE = 1;
localparam integer CAMUS_L14_H = 128;
localparam integer CAMUS_L14_W = 128;
localparam integer CAMUS_L14_IC = 8;
localparam integer CAMUS_L14_OC = 8;
localparam integer CAMUS_L14_K = 3;
localparam integer CAMUS_L14_WEIGHT_OFFSET = 15050;
localparam integer CAMUS_L14_WEIGHT_BYTES = 288;

// 15: dec1.project.0
localparam integer CAMUS_L15_ENGINE = 1;
localparam integer CAMUS_L15_H = 128;
localparam integer CAMUS_L15_W = 128;
localparam integer CAMUS_L15_IC = 8;
localparam integer CAMUS_L15_OC = 4;
localparam integer CAMUS_L15_K = 1;
localparam integer CAMUS_L15_WEIGHT_OFFSET = 15338;
localparam integer CAMUS_L15_WEIGHT_BYTES = 16;

// 16: dec1.refine.0
localparam integer CAMUS_L16_ENGINE = 1;
localparam integer CAMUS_L16_H = 256;
localparam integer CAMUS_L16_W = 256;
localparam integer CAMUS_L16_IC = 8;
localparam integer CAMUS_L16_OC = 4;
localparam integer CAMUS_L16_K = 3;
localparam integer CAMUS_L16_WEIGHT_OFFSET = 15354;
localparam integer CAMUS_L16_WEIGHT_BYTES = 144;

// 17: dec1.refine.3
localparam integer CAMUS_L17_ENGINE = 1;
localparam integer CAMUS_L17_H = 256;
localparam integer CAMUS_L17_W = 256;
localparam integer CAMUS_L17_IC = 4;
localparam integer CAMUS_L17_OC = 4;
localparam integer CAMUS_L17_K = 3;
localparam integer CAMUS_L17_WEIGHT_OFFSET = 15498;
localparam integer CAMUS_L17_WEIGHT_BYTES = 72;

// 18: head
localparam integer CAMUS_L18_ENGINE = 1;
localparam integer CAMUS_L18_H = 256;
localparam integer CAMUS_L18_W = 256;
localparam integer CAMUS_L18_IC = 4;
localparam integer CAMUS_L18_OC = 4;
localparam integer CAMUS_L18_K = 1;
localparam integer CAMUS_L18_WEIGHT_OFFSET = 15570;
localparam integer CAMUS_L18_WEIGHT_BYTES = 8;

`endif
