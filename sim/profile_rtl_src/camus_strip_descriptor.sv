`timescale 1ns/1ps

// Enumerates full-width horizontal strips for AXI DataMover. Geometry,
// transfer length, and command handshake are separate registered stages so
// tail/halo arithmetic cannot become a cross-module critical path.
module camus_strip_descriptor (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [31:0] feature_base_bytes,
    input  logic [19:0] row_words,
    input  logic [31:0] row_bytes,
    input  logic [31:0] tile_stride_bytes,
    input  logic [8:0] frame_height,
    input  logic [8:0] tile_rows,
    input  logic kernel_3x3,

    output logic descriptor_valid,
    input  logic descriptor_ready,
    output logic [71:0] mm2s_command,
    output logic [12:0] source_words,
    output logic [8:0] output_y,
    output logic [8:0] output_rows,
    output logic [19:0] output_row_base_words,
    output logic pad_top,
    output logic pad_bottom,
    output logic last_tile,
    output logic [3:0] tile_tag,

    output logic busy,
    output logic done,
    output logic error
);
    typedef enum logic [2:0] {D_GEOMETRY, D_GEOMETRY_FINAL, D_LENGTH, D_COMMAND, D_READY} desc_state_t;
    desc_state_t desc_state;

    logic [31:0] output_address;
    logic [8:0] tile_y_reg;
    logic [3:0] tag_reg;
    logic [19:0] row_words_reg;
    logic [31:0] row_bytes_reg, tile_stride_bytes_reg;
    logic [8:0] frame_height_reg, tile_rows_reg;
    logic kernel_reg;

    logic [8:0] rows_remaining_calc, output_rows_calc;
    logic top_halo_calc, bottom_halo_calc, last_calc;
    logic [8:0] output_rows_stage_reg;
    logic top_halo_stage_reg;
    logic [9:0] source_rows_calc;
    (* keep = "true", dont_touch = "true" *) logic [9:0] source_rows_reg;
    logic [29:0] source_words_reg;
    logic [31:0] source_address_calc, source_address_reg;
    logic fire;

    assign rows_remaining_calc = frame_height_reg - tile_y_reg;
    assign output_rows_calc = rows_remaining_calc < tile_rows_reg
        ? rows_remaining_calc : tile_rows_reg;
    assign top_halo_calc = kernel_reg && tile_y_reg != 0;
    assign last_calc = tile_y_reg + output_rows_stage_reg == frame_height_reg;
    assign bottom_halo_calc = kernel_reg && !last_calc;
    assign source_rows_calc = output_rows_stage_reg + top_halo_stage_reg + bottom_halo_calc;
    assign source_address_calc = top_halo_stage_reg
        ? output_address - row_bytes_reg : output_address;

    assign descriptor_valid = busy && desc_state == D_READY;
    assign fire = descriptor_valid && descriptor_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            desc_state <= D_GEOMETRY;
            output_address <= '0;
            tile_y_reg <= '0;
            tag_reg <= '0;
            row_words_reg <= '0;
            row_bytes_reg <= '0;
            tile_stride_bytes_reg <= '0;
            frame_height_reg <= '0;
            tile_rows_reg <= '0;
            kernel_reg <= 1'b0;
            output_rows_stage_reg <= '0;
            top_halo_stage_reg <= 1'b0;
            source_rows_reg <= '0;
            source_words_reg <= '0;
            source_address_reg <= '0;
            mm2s_command <= '0;
            source_words <= '0;
            output_y <= '0;
            output_rows <= '0;
            output_row_base_words <= '0;
            pad_top <= 1'b0;
            pad_bottom <= 1'b0;
            last_tile <= 1'b0;
            tile_tag <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && busy)
                error <= 1'b1;

            if (start && !busy) begin
                if (frame_height == 0 || tile_rows == 0 || row_words == 0
                        || row_bytes == 0 || tile_stride_bytes == 0) begin
                    error <= 1'b1;
                end else begin
                    output_address <= feature_base_bytes;
                    tile_y_reg <= 0;
                    tag_reg <= 0;
                    row_words_reg <= row_words;
                    row_bytes_reg <= row_bytes;
                    tile_stride_bytes_reg <= tile_stride_bytes;
                    frame_height_reg <= frame_height;
                    tile_rows_reg <= tile_rows;
                    kernel_reg <= kernel_3x3;
                    desc_state <= D_GEOMETRY;
                    busy <= 1'b1;
                    error <= 1'b0;
                end
            end else if (busy) begin
                case (desc_state)
                    D_GEOMETRY: begin
                        output_rows_stage_reg <= output_rows_calc;
                        top_halo_stage_reg <= top_halo_calc;
                        output_rows <= output_rows_calc;
                        output_y <= tile_y_reg;
                        output_row_base_words <= top_halo_calc ? row_words_reg : 20'd0;
                        pad_top <= kernel_reg && tile_y_reg == 0;
                        tile_tag <= tag_reg;
                        desc_state <= D_GEOMETRY_FINAL;
                    end

                    D_GEOMETRY_FINAL: begin
                        source_rows_reg <= source_rows_calc;
                        source_address_reg <= source_address_calc;
                        output_y <= tile_y_reg;
                        pad_bottom <= kernel_reg && last_calc;
                        last_tile <= last_calc;
                        desc_state <= D_LENGTH;
                    end

                    D_LENGTH: begin
                        source_words_reg <= source_rows_reg * row_words_reg;
                        desc_state <= D_COMMAND;
                    end

                    D_COMMAND: begin
                        if (source_words_reg == 0 || source_words_reg > 4096) begin
                            error <= 1'b1;
                            busy <= 1'b0;
                        end else begin
                            mm2s_command <= '0;
                            mm2s_command[67:64] <= tile_tag;
                            mm2s_command[63:32] <= source_address_reg;
                            mm2s_command[31] <= 1'b1;
                            mm2s_command[30] <= 1'b1;
                            mm2s_command[23] <= 1'b1;
                            mm2s_command[22:0] <= {source_words_reg[19:0], 3'b000};
                            source_words <= source_words_reg[12:0];
                            desc_state <= D_READY;
                        end
                    end

                    D_READY: if (fire) begin
                        if (last_tile) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            output_address <= output_address + tile_stride_bytes_reg;
                            tile_y_reg <= tile_y_reg + tile_rows_reg;
                            tag_reg <= tag_reg + 1'b1;
                            desc_state <= D_GEOMETRY;
                        end
                    end

                    default: desc_state <= D_GEOMETRY;
                endcase
            end
        end
    end
endmodule
