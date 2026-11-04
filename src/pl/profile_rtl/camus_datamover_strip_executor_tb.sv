`timescale 1ns/1ps

module camus_datamover_strip_executor_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [31:0] input_base_bytes = 32'h00001000;
    logic [31:0] output_base_bytes = 32'h00002000;
    logic [19:0] input_row_words = 20'd8;
    logic [31:0] input_row_bytes = 32'd64;
    logic [31:0] input_tile_stride_bytes = 32'd192;
    logic [31:0] output_row_bytes = 32'd64;
    logic [8:0] frame_height = 9'd9;
    logic [8:0] width = 9'd8;
    logic [8:0] tile_rows = 9'd3;
    logic [3:0] input_groups = 4'd1;
    logic [3:0] output_groups = 4'd1;
    logic kernel_3x3 = 1'b0;
    logic [9:0] weight_base = 10'd999;
    logic [5:0] parameter_base = 6'd59;
    logic [6:0] tokens_per_output_group = 7'd1;
    logic relu_enable = 1'b0;
    logic [31:0] watchdog_limit = 32'd100000;

    logic m_axis_mm2s_cmd_tvalid;
    logic m_axis_mm2s_cmd_tready = 1'b1;
    logic [71:0] m_axis_mm2s_cmd_tdata;
    logic s_axis_mm2s_sts_tvalid = 1'b0;
    logic s_axis_mm2s_sts_tready;
    logic [7:0] s_axis_mm2s_sts_tdata = '0;
    logic s_axis_mm2s_tvalid;
    logic s_axis_mm2s_tready;
    logic [127:0] s_axis_mm2s_tdata;
    logic [15:0] s_axis_mm2s_tkeep;
    logic s_axis_mm2s_tlast;

    logic m_axis_s2mm_cmd_tvalid;
    logic m_axis_s2mm_cmd_tready = 1'b1;
    logic [71:0] m_axis_s2mm_cmd_tdata;
    logic s_axis_s2mm_sts_tvalid = 1'b0;
    logic s_axis_s2mm_sts_tready;
    logic [7:0] s_axis_s2mm_sts_tdata = '0;
    logic m_axis_s2mm_tvalid;
    logic m_axis_s2mm_tready;
    logic [127:0] m_axis_s2mm_tdata;
    logic [15:0] m_axis_s2mm_tkeep;
    logic m_axis_s2mm_tlast;
    logic busy, done, error;
    logic [31:0] cycle_count, load_wait_cycles, compute_cycles;
    logic [31:0] output_wait_cycles, output_stall_count;
    logic [15:0] strips_completed;

    integer sim_cycle = 0;
    integer mm_cmd_count = 0;
    integer s2mm_cmd_count = 0;
    integer output_beats = 0;
    integer mm_beats_left = 0;
    integer mm_beat_index = 0;
    integer mm_status_delay = 0;
    integer s2mm_status_delay = 0;
    integer s2mm_bytes_seen = 0;
    integer s2mm_expected_bytes = 0;
    logic mm_active = 1'b0;
    logic s2mm_active = 1'b0;
    logic [3:0] mm_status_tag = '0;
    logic [3:0] s2mm_status_tag = '0;
    logic overlap_seen = 1'b0;

    always #5 clk = ~clk;
    logic [2:0] profile_token_events;
    assign m_axis_s2mm_tready = (sim_cycle % 11) != 0;
    assign s_axis_mm2s_tvalid = mm_active;
    assign s_axis_mm2s_tdata = {16{mm_beat_index[7:0]}};
    assign s_axis_mm2s_tkeep = 16'hffff;
    assign s_axis_mm2s_tlast = mm_active && mm_beats_left == 1;

    camus_datamover_strip_executor #(
        .CACHE_DEPTH(4096), .OUTPUT_FIFO_DEPTH(16)
    ) dut (.*);

    task automatic check_mm2s_command(input integer index);
        integer local_index;
        reg [31:0] expected_address;
        reg [22:0] expected_btt;
        begin
            local_index = index % 3;
            expected_address = 32'h00001000 + local_index * 32'h000000c0;
            expected_btt = 23'd192;
            if (m_axis_mm2s_cmd_tdata[63:32] !== expected_address
                    || m_axis_mm2s_cmd_tdata[22:0] !== expected_btt
                    || m_axis_mm2s_cmd_tdata[67:64] !== local_index[3:0])
                $fatal(1, "MM2S command %0d addr=%h btt=%0d tag=%0d",
                       index, m_axis_mm2s_cmd_tdata[63:32],
                       m_axis_mm2s_cmd_tdata[22:0], m_axis_mm2s_cmd_tdata[67:64]);
        end
    endtask

    task automatic check_s2mm_command(input integer index);
        integer local_index;
        reg [31:0] expected_address;
        reg [22:0] expected_btt;
        begin
            local_index = index % 3;
            expected_address = 32'h00002000 + local_index * 32'h000000c0;
            expected_btt = 23'd192;
            if (m_axis_s2mm_cmd_tdata[63:32] !== expected_address
                    || m_axis_s2mm_cmd_tdata[22:0] !== expected_btt
                    || m_axis_s2mm_cmd_tdata[67:64] !== local_index[3:0])
                $fatal(1, "S2MM command %0d addr=%h btt=%0d tag=%0d",
                       index, m_axis_s2mm_cmd_tdata[63:32],
                       m_axis_s2mm_cmd_tdata[22:0], m_axis_s2mm_cmd_tdata[67:64]);
        end
    endtask

    always @(posedge clk) begin
        if (!rst)
            sim_cycle <= sim_cycle + 1;

        if (m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready) begin
            if (mm_active)
                $fatal(1, "overlapping MM2S command");
            check_mm2s_command(mm_cmd_count);
            mm_active <= 1'b1;
            mm_beats_left <= m_axis_mm2s_cmd_tdata[22:0] / 16;
            mm_beat_index <= 0;
            mm_status_tag <= m_axis_mm2s_cmd_tdata[67:64];
            mm_cmd_count <= mm_cmd_count + 1;
        end

        if (mm_active && s2mm_active)
            overlap_seen <= 1'b1;

        if (s_axis_mm2s_tvalid && s_axis_mm2s_tready) begin
            if (mm_beats_left == 1) begin
                mm_active <= 1'b0;
                mm_status_delay <= 2;
            end else begin
                mm_beats_left <= mm_beats_left - 1;
                mm_beat_index <= mm_beat_index + 1;
            end
        end

        if (mm_status_delay > 0) begin
            mm_status_delay <= mm_status_delay - 1;
            if (mm_status_delay == 1) begin
                s_axis_mm2s_sts_tvalid <= 1'b1;
                s_axis_mm2s_sts_tdata <= {1'b1, 3'b000, mm_status_tag};
            end
        end else if (s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready) begin
            s_axis_mm2s_sts_tvalid <= 1'b0;
        end

        if (m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready) begin
            if (s2mm_active)
                $fatal(1, "overlapping S2MM command");
            check_s2mm_command(s2mm_cmd_count);
            s2mm_active <= 1'b1;
            s2mm_bytes_seen <= 0;
            s2mm_expected_bytes <= m_axis_s2mm_cmd_tdata[22:0];
            s2mm_status_tag <= m_axis_s2mm_cmd_tdata[67:64];
            s2mm_cmd_count <= s2mm_cmd_count + 1;
        end

        if (m_axis_s2mm_tvalid && m_axis_s2mm_tready) begin
            if (!s2mm_active)
                $fatal(1, "S2MM data without command");
            output_beats <= output_beats + 1;
            s2mm_bytes_seen <= s2mm_bytes_seen + 16;
            if (m_axis_s2mm_tkeep !== 16'hffff)
                $fatal(1, "unexpected partial output keep=%h", m_axis_s2mm_tkeep);
            if (m_axis_s2mm_tlast) begin
                if (s2mm_bytes_seen + 16 != s2mm_expected_bytes)
                    $fatal(1, "S2MM byte count got=%0d expected=%0d",
                           s2mm_bytes_seen + 16, s2mm_expected_bytes);
                s2mm_active <= 1'b0;
                s2mm_status_delay <= 2;
            end
        end

        if (s2mm_status_delay > 0) begin
            s2mm_status_delay <= s2mm_status_delay - 1;
            if (s2mm_status_delay == 1) begin
                s_axis_s2mm_sts_tvalid <= 1'b1;
                s_axis_s2mm_sts_tdata <= {1'b1, 3'b000, s2mm_status_tag};
            end
        end else if (s_axis_s2mm_sts_tvalid && s_axis_s2mm_sts_tready) begin
            s_axis_s2mm_sts_tvalid <= 1'b0;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
                @(negedge clk);
                if (error || mm_cmd_count != 3 || s2mm_cmd_count != 3
                        || output_beats != 36 || strips_completed != 3
                        || !overlap_seen)
                    $fatal(1, "executor summary error=%b mm=%0d s2mm=%0d beats=%0d strips=%0d",
                           error, mm_cmd_count, s2mm_cmd_count, output_beats, strips_completed);
                @(negedge clk);
                start = 1'b1;
                @(negedge clk);
                start = 1'b0;
                wait (done);
                @(negedge clk);
                if (error || mm_cmd_count != 6 || s2mm_cmd_count != 6
                        || output_beats != 72 || strips_completed != 3)
                    $fatal(1, "executor restart error=%b mm=%0d s2mm=%0d beats=%0d strips=%0d",
                           error, mm_cmd_count, s2mm_cmd_count, output_beats, strips_completed);
                $display("PASS camus_datamover_strip_executor jobs=2 strips/job=%0d beats=%0d cycles=%0d load_wait=%0d compute=%0d output_wait=%0d stalls=%0d overlap=%0d",
                         strips_completed, output_beats, cycle_count, load_wait_cycles,
                         compute_cycles, output_wait_cycles, output_stall_count, overlap_seen);
                $finish;
            end
            begin
                repeat (120000) @(posedge clk);
                $fatal(1, "executor timeout");
            end
        join_any
    end
endmodule
