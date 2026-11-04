`timescale 1ns/1ps

module camus_layer_job_rom_tb;
    logic [4:0] layer_index;
    logic valid, decoder_engine, kernel_3x3, relu_enable;
    logic [8:0] height, width, tile_rows;
    logic [3:0] input_groups, output_groups, stored_output_groups;
    logic [9:0] weight_base;
    logic [5:0] parameter_base;
    logic [6:0] tokens_per_output_group;
    logic [19:0] input_row_words;
    logic [31:0] input_row_bytes, input_tile_stride_bytes, output_row_bytes;
    integer i;
    integer decoder_count;
    integer source_rows;

    camus_layer_job_rom dut (.*);

    initial begin
        decoder_count = 0;
        for (i = 0; i < 19; i = i + 1) begin
            layer_index = i;
            #1;
            if (!valid || height == 0 || width == 0 || input_groups == 0
                    || output_groups == 0 || tile_rows == 0)
                $fatal(1, "invalid job %0d", i);
            if (input_row_bytes != input_row_words*8)
                $fatal(1, "input stride mismatch job=%0d", i);
            if (input_tile_stride_bytes != tile_rows*input_row_bytes)
                $fatal(1, "tile stride mismatch job=%0d", i);
            if (output_row_bytes[2:0] != 0)
                $fatal(1, "output row is not SIMD8 aligned job=%0d", i);
            if (stored_output_groups != ((output_groups + 1) >> 1))
                $fatal(1, "stored group mismatch job=%0d got=%0d", i,
                       stored_output_groups);
            source_rows = tile_rows < height && kernel_3x3 ? tile_rows+2 : tile_rows;
            if (source_rows*input_row_words > 4096)
                $fatal(1, "cache overflow job=%0d words=%0d", i,
                       source_rows*input_row_words);
            if (decoder_engine)
                decoder_count = decoder_count + 1;
        end
        if (decoder_count != 11)
            $fatal(1, "decoder job count=%0d", decoder_count);

        layer_index = 8; #1;
        if (height != 32 || input_groups != 12 || output_groups != 8
                || kernel_3x3 || weight_base != 594 || parameter_base != 30)
            $fatal(1, "temporal job mismatch");
        layer_index = 18; #1;
        if (relu_enable || weight_base != 999 || output_row_bytes != 2048)
            $fatal(1, "head job mismatch");
        layer_index = 31; #1;
        if (valid)
            $fatal(1, "invalid index accepted");
        $display("PASS camus_layer_job_rom jobs=19 decoder=11");
        $finish;
    end
endmodule
