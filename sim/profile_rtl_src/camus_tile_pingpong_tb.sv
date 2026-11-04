`timescale 1ns/1ps
module camus_tile_pingpong_tb;
    localparam integer DEPTH = 16;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;
    logic wr_start = 0, wr_valid = 0, wr_last = 0;
    logic signed [127:0] wr_data;
    logic wr_ready, wr_done, wr_busy, wr_bank;
    logic [1:0] bank_ready;
    logic rd_en = 0, rd_bank = 0;
    logic [3:0] rd_addr;
    logic signed [127:0] rd_data;
    logic rd_valid, active_bank, overflow;
    integer i;
    camus_tile_pingpong #(.DEPTH(DEPTH)) dut (
        .clk, .rst, .wr_start, .wr_valid, .wr_ready, .wr_data, .wr_last,
        .wr_done, .bank_ready, .wr_busy, .wr_bank, .rd_en, .rd_bank,
        .rd_addr, .rd_data, .rd_valid, .swap_bank(1'b0), .active_bank, .overflow);

    initial begin
        wr_data = '0;
        rd_addr = '0;
        repeat (3) @(posedge clk);
        rst <= 0;
        @(negedge clk); wr_start <= 1;
        @(negedge clk); wr_start <= 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            while (!wr_ready) @(negedge clk);
            @(negedge clk);
            wr_data <= i + 100;
            wr_last <= (i == DEPTH-1);
            wr_valid <= 1;
            @(posedge clk);
            @(negedge clk);
            wr_valid <= 0;
            wr_last <= 0;
        end
        repeat (2) @(posedge clk);
        if (bank_ready[1] !== 1'b1)
            $fatal(1, "tile write did not complete bank_ready=%b", bank_ready);
        rd_bank <= 1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge clk); rd_addr <= i; rd_en <= 1;
            @(posedge clk);
            #1;
            if (!rd_valid || $signed(rd_data) !== i + 100)
                $fatal(1, "tile read mismatch addr=%0d data=%0d", i, $signed(rd_data));
            @(negedge clk); rd_en <= 0;
        end
        if (overflow) $fatal(1, "tile overflow asserted");
        $display("CAMUS tile ping-pong PASS bank_ready=%b", bank_ready);
        $finish;
    end
endmodule
