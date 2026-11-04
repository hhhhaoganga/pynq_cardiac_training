`timescale 1ns/1ps

module camus_output_axis_packer_tb;
    localparam integer TOTAL_GROUPS = 101;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [19:0] total_groups = TOTAL_GROUPS;
    logic [3:0] groups_per_pixel = 4'd2;
    logic in_valid = 1'b0;
    logic [31:0] in_q8 = '0;
    logic output_capacity;
    logic m_axis_tvalid, m_axis_tready;
    logic [127:0] m_axis_tdata;
    logic [15:0] m_axis_tkeep;
    logic m_axis_tlast;
    logic busy, done, error;
    logic [19:0] groups_received, groups_written;
    integer cycle_count = 0;
    integer groups_sent = 0;
    integer beats_seen = 0;
    integer lane;
    integer expected_group;
    logic [31:0] expected_word;

    always #5 clk = ~clk;
    assign m_axis_tready = (cycle_count % 23) >= 18;

    camus_output_axis_packer #(.FIFO_DEPTH(16), .PIPELINE_RESERVE(6)) dut (.*);

    always @(posedge clk) begin
        if (!rst)
            cycle_count <= cycle_count + 1;
        if (!rst && in_valid)
            groups_sent <= groups_sent + 1;

        if (!rst && m_axis_tvalid && m_axis_tready) begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                expected_group = beats_seen * 4 + lane;
                expected_word = {4{expected_group[7:0]}};
                if (expected_group < TOTAL_GROUPS) begin
                    if (m_axis_tdata[lane*32 +: 32] !== expected_word)
                        $fatal(1, "data beat=%0d lane=%0d got=%h expected=%h",
                               beats_seen, lane, m_axis_tdata[lane*32 +: 32], expected_word);
                end else if (m_axis_tdata[lane*32 +: 32] !== 0) begin
                    $fatal(1, "nonzero padded lane beat=%0d lane=%0d", beats_seen, lane);
                end
            end
            if (beats_seen == 25) begin
                if (m_axis_tkeep !== 16'h000f || !m_axis_tlast)
                    $fatal(1, "final beat metadata keep=%h last=%b", m_axis_tkeep, m_axis_tlast);
            end else if (m_axis_tkeep !== 16'hffff || m_axis_tlast) begin
                $fatal(1, "non-final beat metadata beat=%0d keep=%h last=%b",
                       beats_seen, m_axis_tkeep, m_axis_tlast);
            end
            beats_seen <= beats_seen + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && busy && groups_sent < TOTAL_GROUPS && output_capacity) begin
            in_valid = 1'b1;
            in_q8 = {4{groups_sent[7:0]}};
        end else begin
            in_valid = 1'b0;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
                @(negedge clk);
                if (error || groups_received != TOTAL_GROUPS
                        || groups_written != TOTAL_GROUPS || beats_seen != 26)
                    $fatal(1, "packer summary error=%b recv=%0d written=%0d beats=%0d",
                           error, groups_received, groups_written, beats_seen);
                $display("PASS camus_output_axis_packer groups=%0d beats=%0d cycles=%0d",
                         groups_received, beats_seen, cycle_count);
                $finish;
            end
            begin
                repeat (10000) @(posedge clk);
                $fatal(1, "packer timeout");
            end
        join_any
    end
endmodule
