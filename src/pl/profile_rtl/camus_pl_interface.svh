`ifndef CAMUS_PL_INTERFACE_SVH
`define CAMUS_PL_INTERFACE_SVH

// Stable contracts shared by the CAMUS PL layers.
package camus_pl_pkg;
    localparam integer CAMUS_ACT_W = 8;
    localparam integer CAMUS_SIMD = 8;
    localparam integer CAMUS_PE = 4;
    localparam integer CAMUS_FEATURE_W = 64; // SIMD8 UINT8 activation word
    localparam integer CAMUS_FOLDED_W = 32;  // PE4 UINT8 output group
    localparam integer CAMUS_AXI_W = 128;

    typedef enum logic [1:0] {
        CAMUS_PAD_VALID = 2'd0,
        CAMUS_PAD_SAME  = 2'd1
    } camus_pad_mode_t;

    typedef enum logic [1:0] {
        CAMUS_UP_NEAREST = 2'd0,
        CAMUS_UP_DECONV  = 2'd1
    } camus_up_mode_t;

    typedef struct packed {
        logic        enable;
        logic [15:0] width;
        logic [15:0] height;
        logic [15:0] in_channels;
        logic [15:0] out_channels;
        logic [15:0] input_stride;
        logic [15:0] output_stride;
        logic [31:0] activation_base;
        logic [31:0] output_base;
        logic [31:0] weight_base;
        logic [31:0] bias_base;
        logic [31:0] requant_base;
        logic [31:0] weight_bytes;
        logic [2:0]  kernel;
        logic [1:0]  pad_mode;
        logic [1:0]  up_mode;
        logic [3:0]  pe;
        logic [3:0]  simd;
    } camus_layer_cfg_t;

    typedef struct packed {
        logic        sof;
        logic        eof;
        logic        pixel_last;
        logic        frame_last;
        logic [15:0] x;
        logic [15:0] y;
        logic [15:0] group;
    } camus_stream_meta_t;

    typedef struct packed {
        logic        start;
        logic        soft_reset;
        logic        irq_enable;
        logic        abort;
    } camus_control_t;

    typedef struct packed {
        logic        busy;
        logic        done;
        logic        error;
        logic        overflow;
        logic        weight_fault;
        logic        cache_fault;
        logic [31:0] cycles;
    } camus_status_t;
endpackage

// Ready/valid stream with explicit spatial and frame boundaries. Data is
// packed UINT8 lanes; metadata must remain stable while valid && !ready.
interface camus_feature_stream_if #(
    parameter integer DATA_W = camus_pl_pkg::CAMUS_FEATURE_W
) (input logic clk, input logic rst);
    logic valid;
    logic ready;
    logic signed [DATA_W-1:0] data;
    logic sof;
    logic eof;
    logic pixel_last;
    logic frame_last;
    logic [15:0] x;
    logic [15:0] y;
    logic [15:0] group;

    modport source (
        input clk, input rst, output valid, input ready, output data,
        output sof, output eof, output pixel_last, output frame_last,
        output x, output y, output group
    );
    modport sink (
        input clk, input rst, input valid, output ready, input data,
        input sof, input eof, input pixel_last, input frame_last,
        input x, input y, input group
    );
endinterface

`endif
