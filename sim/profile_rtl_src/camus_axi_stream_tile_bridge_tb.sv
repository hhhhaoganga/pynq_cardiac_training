`timescale 1ns/1ps
module camus_axi_stream_tile_bridge_tb;
    localparam integer N = 8;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1, load_start = 0, read_start = 0, read_bank = 1;
    logic [4:0] load_beats = N, read_beats = N;
    logic s_valid = 0, s_ready, s_last;
    logic signed [127:0] s_data;
    logic [15:0] s_keep = 16'hffff;
    logic m_valid, m_ready = 1, m_last;
    logic signed [127:0] m_data;
    logic [15:0] m_keep;
    logic load_done, read_done, busy, error;
    logic [1:0] bank_ready;
    integer i, got;
    camus_axi_stream_tile_bridge #(.DEPTH(16)) dut (
        .clk, .rst, .load_start, .load_beats, .read_beats, .read_start, .read_bank,
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tdata(s_data),
        .s_axis_tkeep(s_keep), .s_axis_tlast(s_last), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tlast(m_last), .load_done, .read_done, .busy, .error, .bank_ready);
    always @(posedge clk) begin
        if (m_valid && m_ready) begin
            if ($signed(m_data) !== got + 1000)
                $fatal(1, "AXIS read mismatch got=%0d expected=%0d", $signed(m_data), got + 1000);
            if (m_last !== (got == N-1)) $fatal(1, "AXIS tlast mismatch beat=%0d", got);
            got <= got + 1;
        end
    end
    initial begin
        s_data = '0; s_last = 0; got = 0;
        repeat (3) @(posedge clk);
        rst <= 0;
        @(negedge clk); load_start <= 1;
        @(negedge clk); load_start <= 0;
        for (i = 0; i < N; i = i + 1) begin
            while (!s_ready) @(negedge clk);
            @(negedge clk); s_data <= i + 1000; s_last <= (i == N-1); s_valid <= 1;
            @(posedge clk); @(negedge clk); s_valid <= 0; s_last <= 0;
        end
        repeat (2) @(posedge clk);
        if (bank_ready[1] !== 1'b1) $fatal(1, "AXIS load did not complete");
        @(negedge clk); read_start <= 1;
        @(negedge clk); read_start <= 0;
        wait (read_done);
        #1;
        if (got != N || error) $fatal(1, "AXIS read failed got=%0d error=%b", got, error);
        $display("CAMUS AXI-stream tile bridge PASS beats=%0d", got);
        $finish;
    end
endmodule
