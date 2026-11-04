`timescale 1ns/1ps

// Runs one fixed graph phase. Instantiate FIRST_OP=0/LAST_OP=10 for the
// encoder and FIRST_OP=11/LAST_OP=28 for the decoder. The two instances can
// operate concurrently on adjacent frames.
module camus_phase_scheduler #(
    parameter integer FIRST_OP = 0,
    parameter integer LAST_OP = 10,
    parameter logic [31:0] SCRATCH_STRIDE = 32'h0010_0000
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic op_done,
    input  logic op_error,

    input  logic [31:0] input_base,
    input  logic [31:0] mask_base,
    input  logic [31:0] skip_base,
    input  logic [31:0] scratch_base,

    output logic op_start,
    output logic [2:0] op_kind,
    output logic [4:0] op_index,
    output logic [4:0] layer_index,
    output logic [31:0] source_address,
    output logic [31:0] source_b_address,
    output logic [31:0] dest_address,

    output logic [8:0] height,
    output logic [8:0] width,
    output logic [8:0] tile_rows,
    output logic [3:0] input_groups,
    output logic [3:0] output_groups,
    output logic [3:0] stored_output_groups,
    output logic kernel_3x3,
    output logic [9:0] weight_base,
    output logic [5:0] parameter_base,
    output logic [6:0] tokens_per_output_group,
    output logic relu_enable,
    output logic [19:0] input_row_words,
    output logic [31:0] input_row_bytes,
    output logic [31:0] input_tile_stride_bytes,
    output logic [31:0] output_row_bytes,

    output logic busy,
    output logic done,
    output logic error,
    output logic [63:0] cycle_count
);
    typedef enum logic [1:0] {S_IDLE, S_LAUNCH, S_WAIT} state_t;
    state_t state;
    logic op_valid, decoder_phase;
    logic [2:0] rom_op_kind,source_sel,source_b_sel,dest_sel;
    logic [4:0] rom_layer_index;
    logic layer_valid, layer_decoder;
    logic [8:0] rom_height,rom_width,rom_tile_rows;
    logic [3:0] rom_input_groups,rom_output_groups,rom_stored_output_groups;
    logic rom_kernel_3x3,rom_relu_enable;
    logic [9:0] rom_weight_base;
    logic [5:0] rom_parameter_base;
    logic [6:0] rom_tokens_per_output_group;
    logic [19:0] rom_input_row_words;
    logic [31:0] rom_input_row_bytes,rom_input_tile_stride_bytes;
    logic [31:0] rom_output_row_bytes;

    localparam logic [2:0] BUF_INPUT    = 3'd0;
    localparam logic [2:0] BUF_SCRATCH0 = 3'd1;
    localparam logic [2:0] BUF_SCRATCH1 = 3'd2;
    localparam logic [2:0] BUF_SKIP1    = 3'd3;
    localparam logic [2:0] BUF_SKIP2    = 3'd4;
    localparam logic [2:0] BUF_SKIP3    = 3'd5;
    localparam logic [2:0] BUF_HISTORY  = 3'd6;
    localparam logic [2:0] BUF_MASK     = 3'd7;

    camus_frame_op_rom u_op_rom (
        .op_index(op_index), .valid(op_valid), .decoder_phase(decoder_phase),
        .op_kind(rom_op_kind), .layer_index(rom_layer_index),
        .source_sel(source_sel), .source_b_sel(source_b_sel), .dest_sel(dest_sel)
    );

    camus_layer_job_rom u_layer_rom (
        .layer_index(rom_layer_index), .valid(layer_valid),
        .decoder_engine(layer_decoder), .height(rom_height), .width(rom_width),
        .input_groups(rom_input_groups), .output_groups(rom_output_groups),
        .stored_output_groups(rom_stored_output_groups),
        .kernel_3x3(rom_kernel_3x3), .weight_base(rom_weight_base),
        .parameter_base(rom_parameter_base),
        .tokens_per_output_group(rom_tokens_per_output_group),
        .relu_enable(rom_relu_enable), .tile_rows(rom_tile_rows),
        .input_row_words(rom_input_row_words),
        .input_row_bytes(rom_input_row_bytes),
        .input_tile_stride_bytes(rom_input_tile_stride_bytes),
        .output_row_bytes(rom_output_row_bytes)
    );

    function automatic logic [31:0] resolve_buffer(input logic [2:0] sel);
        case (sel)
            BUF_INPUT:     resolve_buffer = input_base;
            BUF_SCRATCH0:  resolve_buffer = scratch_base;
            BUF_SCRATCH1:  resolve_buffer = scratch_base + SCRATCH_STRIDE;
            BUF_SKIP1:     resolve_buffer = skip_base;
            BUF_SKIP2:     resolve_buffer = skip_base + 32'h0008_0000;
            BUF_SKIP3:     resolve_buffer = skip_base + 32'h000A_0000;
            BUF_MASK:      resolve_buffer = mask_base;
            default:       resolve_buffer = 32'd0;
        endcase
    endfunction

    assign busy = state != S_IDLE;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            op_index <= FIRST_OP[4:0];
            op_start <= 1'b0;
            op_kind<=0;layer_index<=0;source_address<=0;source_b_address<=0;
            dest_address<=0;height<=0;width<=0;tile_rows<=0;
            input_groups<=0;output_groups<=0;stored_output_groups<=0;
            kernel_3x3<=0;weight_base<=0;parameter_base<=0;
            tokens_per_output_group<=0;relu_enable<=0;
            input_row_words<=0;input_row_bytes<=0;
            input_tile_stride_bytes<=0;output_row_bytes<=0;
            done <= 1'b0;
            error <= 1'b0;
            cycle_count <= 0;
        end else begin
            op_start <= 1'b0;
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 1'b1;

            if (start && busy)
                error <= 1'b1;

            case (state)
                S_IDLE: if (start) begin
                    op_index <= FIRST_OP[4:0];
                    cycle_count <= 0;
                    error <= 1'b0;
                    state <= S_LAUNCH;
                end
                S_LAUNCH: begin
                    if (!op_valid || (rom_op_kind == 0 && !layer_valid)) begin
                        error <= 1'b1;
                        done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        op_kind<=rom_op_kind;layer_index<=rom_layer_index;
                        source_address<=source_sel==BUF_HISTORY
                            ? 32'd0:resolve_buffer(source_sel);
                        source_b_address<=resolve_buffer(source_b_sel);
                        dest_address<=dest_sel==BUF_HISTORY
                            ? 32'd0:resolve_buffer(dest_sel);
                        height<=rom_height;width<=rom_width;tile_rows<=rom_tile_rows;
                        input_groups<=rom_input_groups;
                        output_groups<=rom_output_groups;
                        stored_output_groups<=rom_stored_output_groups;
                        kernel_3x3<=rom_kernel_3x3;
                        weight_base<=rom_weight_base;
                        parameter_base<=rom_parameter_base;
                        tokens_per_output_group<=rom_tokens_per_output_group;
                        relu_enable<=rom_relu_enable;
                        input_row_words<=rom_input_row_words;
                        input_row_bytes<=rom_input_row_bytes;
                        input_tile_stride_bytes<=rom_input_tile_stride_bytes;
                        output_row_bytes<=rom_output_row_bytes;
                        op_start <= 1'b1;
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (op_error) begin
                        error <= 1'b1;
                        done <= 1'b1;
                        state <= S_IDLE;
                    end else if (op_done) begin
                        if (op_index == LAST_OP[4:0]) begin
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            op_index <= op_index + 1'b1;
                            state <= S_LAUNCH;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
