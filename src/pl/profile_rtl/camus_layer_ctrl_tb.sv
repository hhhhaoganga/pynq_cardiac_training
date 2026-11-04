`timescale 1ns/1ps
module camus_layer_ctrl_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1, start = 0, soft_reset = 0, abort = 0;
    logic load_done = 0, compute_done = 0, writeback_done = 0;
    logic load_active, compute_active, writeback_active, busy, done, error;
    logic [31:0] cycle_count, active_width, active_height, active_in_channels, active_out_channels;
    logic [1:0] phase;
    camus_layer_ctrl dut (
        .clk, .rst, .start, .soft_reset, .abort, .load_done, .compute_done,
        .writeback_done, .load_active, .compute_active, .writeback_active,
        .busy, .done, .error, .cycle_count, .phase,
        .cfg_width(32'd256), .cfg_height(32'd256), .cfg_in_channels(32'd16),
        .cfg_out_channels(32'd32), .active_width, .active_height,
        .active_in_channels, .active_out_channels);
    initial begin
        repeat (2) @(posedge clk);
        rst <= 0;
        @(negedge clk); start <= 1;
        @(negedge clk); start <= 0;
        @(posedge clk);
        if (!busy || !load_active) $fatal(1, "controller did not enter LOAD");
        repeat (3) @(posedge clk);
        @(negedge clk); load_done <= 1; @(posedge clk); @(negedge clk); load_done <= 0;
        #1;
        if (!compute_active) $fatal(1, "controller did not enter COMPUTE");
        repeat (4) @(posedge clk);
        @(negedge clk); compute_done <= 1; @(posedge clk); @(negedge clk); compute_done <= 0;
        #1;
        if (!writeback_active) $fatal(1, "controller did not enter WRITEBACK");
        repeat (2) @(posedge clk);
        @(negedge clk); writeback_done <= 1; @(posedge clk); @(negedge clk); writeback_done <= 0;
        #1;
        if (!done || busy || error) $fatal(1, "controller completion mismatch");
        if (cycle_count == 0 || active_width != 256 || active_out_channels != 32)
            $fatal(1, "controller config/cycle mismatch");
        $display("CAMUS layer controller PASS cycles=%0d", cycle_count);
        $finish;
    end
endmodule
