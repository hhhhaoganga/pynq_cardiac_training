`timescale 1ns/1ps

module camus_output_axis_packer_pad_tb;
    localparam integer TOTAL_GROUPS = 9;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [19:0] total_groups = TOTAL_GROUPS;
    logic [3:0] groups_per_pixel = 4'd1;
    logic in_valid = 1'b0;
    logic [31:0] in_q8 = '0;
    logic output_capacity;
    logic m_axis_tvalid, m_axis_tready = 1'b1;
    logic [127:0] m_axis_tdata;
    logic [15:0] m_axis_tkeep;
    logic m_axis_tlast;
    logic busy, done, error;
    logic [19:0] groups_received, groups_written;
    integer sent = 0;
    integer physical_group = 0;
    integer lane;
    logic [7:0] expected_byte;

    always #5 clk = ~clk;
    camus_output_axis_packer #(.FIFO_DEPTH(16), .PIPELINE_RESERVE(6)) dut (.*);

    always @(negedge clk) begin
        if (!rst && busy && sent < TOTAL_GROUPS && output_capacity) begin
            in_valid = 1'b1;
            in_q8 = {4{sent[7:0]}};
        end else begin
            in_valid = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst && in_valid)
            sent <= sent + 1;
        if (!rst && m_axis_tvalid && m_axis_tready) begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (physical_group + lane < TOTAL_GROUPS*2) begin
                    if (((physical_group + lane) & 1) == 0) begin
                        expected_byte = (physical_group + lane) / 2;
                        if (m_axis_tdata[lane*32 +: 32]
                                !== {4{expected_byte}})
                            $fatal(1, "real group mismatch index=%0d", physical_group+lane);
                    end else if (m_axis_tdata[lane*32 +: 32] !== 0) begin
                        $fatal(1, "padding group is nonzero index=%0d", physical_group+lane);
                    end
                end
            end
            physical_group <= physical_group + 4;
            if (m_axis_tlast && m_axis_tkeep !== 16'h00ff)
                $fatal(1, "bad final keep=%h", m_axis_tkeep);
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 1'b0; start = 1'b1;
        @(negedge clk); start = 1'b0;
        wait (done);
        @(negedge clk);
        if (error || groups_received != TOTAL_GROUPS || groups_written != 18)
            $fatal(1, "pad summary error=%b received=%0d written=%0d",
                   error, groups_received, groups_written);
        $display("PASS camus_output_axis_packer_pad real=%0d physical=%0d",
                 groups_received, groups_written);
        $finish;
    end
endmodule
