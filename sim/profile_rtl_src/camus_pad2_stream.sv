`timescale 1ns/1ps
// Same-padding adapter for the valid-window PE2 3x3 layer.
//
// The wrapped convolution consumes a raster stream and emits one output
// pixel for every valid 3x3 window.  This adapter inserts a zero border,
// turning an input WIDTH x HEIGHT frame into (WIDTH+2) x (HEIGHT+2).  The
// wrapped layer therefore emits exactly WIDTH x HEIGHT output pixels while
// retaining its existing line-buffer implementation.
module camus_pad2_stream #(
    parameter integer WIDTH = 256,
    parameter integer HEIGHT = 256,
    parameter integer IN_CH = 3,
    parameter integer OUT_CH = 16,
    parameter integer LAYER_ID = 0,
    parameter integer PE = 2,
    parameter integer SIMD = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic in_valid,
    input  logic signed [IN_CH*8-1:0] in_pixel,
    output logic in_ready,
    output logic out_valid,
    output logic signed [PE*8-1:0] out_data,
    output logic out_pixel_last,
    output logic out_last,
    output logic busy,
    output logic done
);
    localparam integer PAD_WIDTH = WIDTH + 2;
    localparam integer GROUPS = (OUT_CH + PE - 1) / PE;

    logic conv_in_valid;
    logic signed [IN_CH*8-1:0] conv_in_pixel;
    logic conv_in_ready;
    logic conv_out_valid;
    logic signed [PE*8-1:0] conv_out_data;
    logic conv_out_pixel_last;
    logic conv_out_last;
    logic conv_busy;

    integer pad_x, pad_y;
    integer out_pixels;
    logic active;

    wire interior = (pad_x >= 1) && (pad_x <= WIDTH) &&
                    (pad_y >= 1) && (pad_y <= HEIGHT);
    wire border = !interior;
    wire pad_handshake = conv_in_valid && conv_in_ready;

    assign busy = active || conv_busy;
    assign conv_in_valid = active && (border ? 1'b1 : in_valid);
    assign conv_in_pixel = border ? '0 : in_pixel;
    // A source pixel is consumed only when the wrapped layer accepts it.
    // Border cycles have no source-side handshake.
    assign in_ready = active && interior && conv_in_ready;

    assign out_valid = conv_out_valid;
    assign out_data = conv_out_data;
    assign out_pixel_last = conv_out_pixel_last;
    assign out_last = conv_out_valid && conv_out_pixel_last &&
                      (out_pixels == WIDTH*HEIGHT-1);

    camus_conv3x3_pe2_layer #(
        .LAYER_ID(LAYER_ID),
        .WIDTH(PAD_WIDTH),
        .PE(PE),
        .SIMD(SIMD),
        .IN_CH(IN_CH),
        .OUT_CH(OUT_CH)
    ) u_conv (
        .clk(clk),
        .rst(rst),
        .in_valid(conv_in_valid),
        .in_pixel(conv_in_pixel),
        .in_ready(conv_in_ready),
        .out_valid(conv_out_valid),
        .out_data(conv_out_data),
        .out_pixel_last(conv_out_pixel_last),
        .out_last(conv_out_last),
        .busy(conv_busy)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            pad_x <= 0;
            pad_y <= 0;
            out_pixels <= 0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !active && !conv_busy) begin
                active <= 1'b1;
                pad_x <= 0;
                pad_y <= 0;
                out_pixels <= 0;
            end

            if (active && pad_handshake) begin
                if (pad_x == PAD_WIDTH-1) begin
                    pad_x <= 0;
                    if (pad_y == HEIGHT+1) begin
                        // The final padded input has been accepted.  Keep
                        // active high until the final output pixel drains.
                        active <= 1'b0;
                    end else begin
                        pad_y <= pad_y + 1;
                    end
                end else begin
                    pad_x <= pad_x + 1;
                end
            end

            if (conv_out_valid && conv_out_pixel_last) begin
                if (out_pixels == WIDTH*HEIGHT-1) begin
                    out_pixels <= 0;
                    done <= 1'b1;
                end else begin
                    out_pixels <= out_pixels + 1;
                end
            end
        end
    end
endmodule
