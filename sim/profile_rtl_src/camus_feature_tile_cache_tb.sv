`timescale 1ns/1ps

module camus_feature_tile_cache_tb;
    localparam integer DEPTH = 32;
    localparam integer TILES = 1000;
    localparam integer ADDR_W = $clog2(DEPTH);

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic load_start = 1'b0;
    logic [ADDR_W:0] load_words = DEPTH;
    logic s_axis_tvalid = 1'b0;
    logic s_axis_tready;
    logic [127:0] s_axis_tdata = '0;
    logic [15:0] s_axis_tkeep = 16'hffff;
    logic s_axis_tlast = 1'b0;
    logic load_done, load_busy, loaded_bank;
    logic read_enable = 1'b0;
    logic read_bank = 1'b0;
    logic [ADDR_W-1:0] read_address = '0;
    logic [63:0] read_data;
    logic read_valid;
    logic [1:0] bank_ready;
    logic error;
    integer tile;

    always #5 clk = ~clk;

    camus_feature_tile_cache #(.DEPTH(DEPTH)) dut (
        .clk, .rst, .load_start, .load_words,
        .s_axis_tvalid, .s_axis_tready, .s_axis_tdata,
        .s_axis_tkeep, .s_axis_tlast,
        .load_done, .load_busy, .loaded_bank,
        .read_enable, .read_bank, .read_address,
        .read_data, .read_valid, .bank_ready, .error
    );

    function automatic [63:0] expected_word(input integer tile_id, input integer index);
        expected_word = tile_id * DEPTH + index + 64'h1000;
    endfunction

    task automatic load_one(input integer tile_id);
        integer beat;
        begin
            @(negedge clk);
            load_start = 1'b1;
            @(negedge clk);
            load_start = 1'b0;
            for (beat = 0; beat < DEPTH/2; beat = beat + 1) begin
                while (!s_axis_tready) @(negedge clk);
                s_axis_tdata = {
                    expected_word(tile_id, beat*2 + 1),
                    expected_word(tile_id, beat*2)
                };
                s_axis_tlast = beat == DEPTH/2 - 1;
                s_axis_tvalid = 1'b1;
                @(negedge clk);
                s_axis_tvalid = 1'b0;
                s_axis_tlast = 1'b0;
            end
            wait (load_done);
            @(negedge clk);
        end
    endtask

    task automatic read_one(input integer tile_id, input logic bank_id);
        integer index;
        begin
            read_bank = bank_id;
            for (index = 0; index < DEPTH; index = index + 1) begin
                @(negedge clk);
                read_address = index[ADDR_W-1:0];
                read_enable = 1'b1;
                @(posedge clk);
                #1;
                if (!read_valid || read_data !== expected_word(tile_id, index))
                    $fatal(1, "tile=%0d bank=%0d index=%0d got=%h expected=%h",
                           tile_id, bank_id, index, read_data, expected_word(tile_id, index));
            end
            @(negedge clk);
            read_enable = 1'b0;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        load_one(0);
        if (loaded_bank !== 1'b1)
            $fatal(1, "first tile expected bank 1, got %0d", loaded_bank);

        for (tile = 1; tile < TILES; tile = tile + 1) begin
            fork
                load_one(tile);
                read_one(tile - 1, ~((tile - 1) & 1));
            join
            if (error)
                $fatal(1, "cache error after tile %0d", tile);
        end
        read_one(TILES - 1, ~((TILES - 1) & 1));

        if (error)
            $fatal(1, "cache error at completion");
        $display("PASS camus_feature_tile_cache tiles=%0d words=%0d", TILES, TILES*DEPTH);
        $finish;
    end
endmodule
