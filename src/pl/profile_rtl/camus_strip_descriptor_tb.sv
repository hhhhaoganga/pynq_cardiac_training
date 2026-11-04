`timescale 1ns/1ps

module camus_strip_descriptor_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [31:0] feature_base_bytes;
    logic [19:0] row_words;
    logic [31:0] row_bytes, tile_stride_bytes;
    logic [8:0] frame_height, tile_rows;
    logic kernel_3x3;
    logic descriptor_valid, descriptor_ready = 1'b0;
    logic [71:0] mm2s_command;
    logic [12:0] source_words;
    logic [8:0] output_y, output_rows;
    logic [19:0] output_row_base_words;
    logic pad_top, pad_bottom, last_tile;
    logic [3:0] tile_tag;
    logic busy, done, error;
    integer index;

    always #5 clk = ~clk;

    camus_strip_descriptor dut (.*);

    task automatic launch(
        input [31:0] base,
        input [19:0] words_per_row,
        input [8:0] height,
        input [8:0] rows,
        input logic k3
    );
        begin
            feature_base_bytes = base;
            row_words = words_per_row;
            row_bytes = words_per_row * 8;
            tile_stride_bytes = words_per_row * rows * 8;
            frame_height = height;
            tile_rows = rows;
            kernel_3x3 = k3;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic accept_one;
        begin
            descriptor_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            descriptor_ready = 1'b0;
        end
    endtask

    initial begin
        feature_base_bytes = 0;
        row_words = 0;
        row_bytes = 0;
        tile_stride_bytes = 0;
        frame_height = 0;
        tile_rows = 0;
        kernel_3x3 = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // 256x256, one SIMD8 group, 14 output rows per 4096-word cache.
        launch(32'h10000000, 256, 256, 14, 1'b1);
        for (index = 0; index < 19; index = index + 1) begin
            wait (descriptor_valid);
            if (tile_tag !== index[3:0]) $fatal(1, "tag %0d got %0d", index, tile_tag);
            if (mm2s_command[67:64] !== index[3:0])
                $fatal(1, "command tag %0d got %0d", index, mm2s_command[67:64]);
            if (mm2s_command[23] !== 1'b1 || mm2s_command[31:30] !== 2'b11)
                $fatal(1, "command control bits incorrect");
            if (mm2s_command[22:0] !== source_words * 8)
                $fatal(1, "BTT mismatch index=%0d", index);
            if (index == 0) begin
                if (output_y != 0 || output_rows != 14 || source_words != 3840
                        || !pad_top || pad_bottom || output_row_base_words != 0
                        || mm2s_command[63:32] != 32'h10000000)
                    $fatal(1, "first strip mismatch");
            end else if (index == 18) begin
                if (output_y != 252 || output_rows != 4 || source_words != 1280
                        || pad_top || !pad_bottom || output_row_base_words != 256
                        || !last_tile
                        || mm2s_command[63:32] != 32'h1007d800)
                    $fatal(1, "last strip mismatch addr=%h words=%0d",
                           mm2s_command[63:32], source_words);
            end else if (source_words != 4096 || output_row_base_words != 256)
                $fatal(1, "middle strip mismatch index=%0d words=%0d", index, source_words);
            accept_one();
        end
        wait (done);
        if (error) $fatal(1, "3x3 descriptor error");

        // 32x32, 96 channels, pointwise temporal layer: 384 words/row.
        launch(32'h20000000, 384, 32, 10, 1'b0);
        for (index = 0; index < 4; index = index + 1) begin
            wait (descriptor_valid);
            if (mm2s_command[63:32] != 32'h20000000 + index * 30720)
                $fatal(1, "1x1 source address mismatch index=%0d got=%h",
                    index, mm2s_command[63:32]);
            if (index < 3 && (output_rows != 10 || source_words != 3840))
                $fatal(1, "1x1 full strip mismatch index=%0d", index);
            if (index == 3 && (output_y != 30 || output_rows != 2
                    || source_words != 768 || !last_tile))
                $fatal(1, "1x1 tail strip mismatch");
            if (pad_top || pad_bottom || output_row_base_words != 0)
                $fatal(1, "1x1 padding metadata mismatch");
            accept_one();
        end
        wait (done);
        if (error) $fatal(1, "1x1 descriptor error");

        $display("PASS camus_strip_descriptor 3x3_tiles=19 pointwise_tiles=4");
        $finish;
    end
endmodule
