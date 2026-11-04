`timescale 1ns/1ps
module camus_enc12_pool_tile_tb;
    localparam integer W = 8;
    localparam integer H = 8;
    localparam integer DEPTH = (W/2)*(H/2);
    localparam integer ADDR_W = $clog2(DEPTH);
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1, start = 1'b0, in_valid = 1'b0;
    logic signed [23:0] in_pixel = '0;
    logic in_ready, busy, done, fifo_overflow, wr_done, wr_bank, cache_overflow;
    logic [1:0] bank_ready;
    logic read_start = 1'b0, read_bank = 1'b0, read_en = 1'b0;
    logic [ADDR_W-1:0] read_addr = '0;
    logic signed [127:0] read_data;
    logic read_valid;
    integer y, x, ch, reads, last_count;
    reg [31:0] checksum;

    camus_enc12_pool_tile #(.WIDTH(W), .HEIGHT(H), .TILE_DEPTH(DEPTH), .FIFO_DEPTH(256)) dut (
        .clk, .rst, .start, .in_valid, .in_pixel, .in_ready, .busy, .done,
        .fifo_overflow, .wr_done, .bank_ready, .wr_bank,
        .read_start, .read_bank, .read_addr, .read_en,
        .read_data, .read_valid, .cache_overflow);

    always @(posedge clk) begin
        if (read_valid) begin
            checksum = {checksum[23:0], checksum[31:24]} ^ read_data[31:0] ^ read_data[63:32] ^
                       read_data[95:64] ^ read_data[127:96];
            reads = reads + 1;
            if (read_addr == DEPTH-1) last_count = last_count + 1;
        end
    end

    initial begin
        reads = 0; last_count = 0; checksum = 32'h2468ace0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                @(negedge clk);
                for (ch = 0; ch < 3; ch = ch + 1)
                    in_pixel[ch*8 +: 8] = $signed((y + 7) * (x + 2) + ch - 24);
                in_valid <= 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (in_ready) break;
                end
                @(negedge clk); in_valid <= 1'b0;
            end
        end
        wait (wr_done);
        if (bank_ready[wr_bank ^ 1'b1] !== 1'b1)
            $fatal(1, "written bank not ready bank_ready=%b wr_bank=%b", bank_ready, wr_bank);

        // Read back the completed bank through the cache's registered port.
        read_bank <= wr_bank ^ 1'b1;
        @(negedge clk); read_start <= 1'b1;
        @(negedge clk); read_start <= 1'b0;
        for (x = 0; x < DEPTH; x = x + 1) begin
            @(negedge clk); read_addr <= x[ADDR_W-1:0]; read_en <= 1'b1;
            @(posedge clk);
            @(negedge clk); read_en <= 1'b0;
        end
        repeat (10) @(posedge clk);
        if (fifo_overflow || cache_overflow)
            $fatal(1, "tile cache overflow fifo=%b cache=%b", fifo_overflow, cache_overflow);
        if (reads != DEPTH)
            $fatal(1, "tile read count mismatch got=%0d expected=%0d", reads, DEPTH);
        $display("CAMUS enc12 pool tile cache PASS reads=%0d checksum=%08x", reads, checksum);
        $finish;
    end
endmodule
