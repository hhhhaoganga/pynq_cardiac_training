`timescale 1ns/1ps

module camus_pool_datamover_executor_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [31:0] input_base_bytes = 32'h0010_0000;
    logic [31:0] output_base_bytes = 32'h0020_0000;
    logic [8:0] width = 9'd4;
    logic [8:0] height = 9'd4;
    logic [2:0] groups = 3'd1;
    logic [3:0] command_tag = 4'ha;
    logic [31:0] watchdog_limit = 32'd10000;

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
    logic [63:0] cycle_count;
    logic [31:0] input_stall_cycles, output_stall_cycles;

    logic [63:0] input_words [0:15];
    logic [63:0] expected_words [0:3];
    integer input_beat = 0;
    integer output_word = 0;
    integer status_delay_mm = 0;
    integer status_delay_s2 = 0;
    integer cycle = 0;
    logic mm_active = 1'b0;
    logic s2_active = 1'b0;

    always #5 clk = ~clk;
    assign s_axis_mm2s_tvalid = mm_active;
    assign s_axis_mm2s_tdata = {input_words[input_beat*2+1], input_words[input_beat*2]};
    assign s_axis_mm2s_tkeep = 16'hffff;
    assign s_axis_mm2s_tlast = mm_active && input_beat == 7;
    assign m_axis_s2mm_tready = (cycle % 7) != 3;

    camus_pool_datamover_executor dut (.*);

    function automatic [63:0] make_word(input integer pixel);
        integer lane;
        begin
            for (lane = 0; lane < 8; lane = lane + 1)
                make_word[lane*8 +: 8] = pixel * 8 + lane;
        end
    endfunction

    task automatic check_output_word(input logic [63:0] value);
        begin
            if (value !== expected_words[output_word])
                $fatal(1, "pool output %0d got=%h expected=%h",
                       output_word, value, expected_words[output_word]);
            output_word = output_word + 1;
        end
    endtask

    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            input_words[i] = make_word(i);
        // Raster-order maxima of each 2x2 region: pixels 5, 7, 13 and 15.
        expected_words[0] = make_word(5);
        expected_words[1] = make_word(7);
        expected_words[2] = make_word(13);
        expected_words[3] = make_word(15);
    end

    always @(posedge clk) begin
        if (!rst)
            cycle <= cycle + 1;

        if (m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready) begin
            if (m_axis_mm2s_cmd_tdata[63:32] !== input_base_bytes
                    || m_axis_mm2s_cmd_tdata[22:0] !== 23'd128
                    || m_axis_mm2s_cmd_tdata[67:64] !== command_tag)
                $fatal(1, "bad MM2S command %h", m_axis_mm2s_cmd_tdata);
            mm_active <= 1'b1;
            input_beat <= 0;
        end

        if (s_axis_mm2s_tvalid && s_axis_mm2s_tready) begin
            if (input_beat == 7) begin
                mm_active <= 1'b0;
                status_delay_mm <= 4;
            end else begin
                input_beat <= input_beat + 1;
            end
        end

        if (status_delay_mm > 0) begin
            status_delay_mm <= status_delay_mm - 1;
            if (status_delay_mm == 1) begin
                s_axis_mm2s_sts_tvalid <= 1'b1;
                s_axis_mm2s_sts_tdata <= {1'b1, 3'b000, command_tag};
            end
        end else if (s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready) begin
            s_axis_mm2s_sts_tvalid <= 1'b0;
        end

        if (m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready) begin
            if (m_axis_s2mm_cmd_tdata[63:32] !== output_base_bytes
                    || m_axis_s2mm_cmd_tdata[22:0] !== 23'd32
                    || m_axis_s2mm_cmd_tdata[67:64] !== command_tag)
                $fatal(1, "bad S2MM command %h", m_axis_s2mm_cmd_tdata);
            s2_active <= 1'b1;
        end

        if (m_axis_s2mm_tvalid && m_axis_s2mm_tready) begin
            if (!s2_active)
                $fatal(1, "S2MM data arrived without an active command");
            if (m_axis_s2mm_tkeep !== 16'hffff)
                $fatal(1, "bad S2MM keep %h", m_axis_s2mm_tkeep);
            check_output_word(m_axis_s2mm_tdata[63:0]);
            check_output_word(m_axis_s2mm_tdata[127:64]);
            if (m_axis_s2mm_tlast) begin
                if (output_word != 4)
                    $fatal(1, "early S2MM last after %0d words", output_word);
                s2_active <= 1'b0;
                // Return status well after pool_done to verify completion latching.
                status_delay_s2 <= 6;
            end
        end

        if (status_delay_s2 > 0) begin
            status_delay_s2 <= status_delay_s2 - 1;
            if (status_delay_s2 == 1) begin
                s_axis_s2mm_sts_tvalid <= 1'b1;
                s_axis_s2mm_sts_tdata <= {1'b1, 3'b000, command_tag};
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

        fork : completion_or_timeout
            begin
                wait (done);
                @(negedge clk);
                if (error || output_word != 4 || busy)
                    $fatal(1, "pool executor summary error=%b words=%0d busy=%b",
                           error, output_word, busy);
                $display("PASS camus_pool_datamover_executor words=%0d cycles=%0d input_stall=%0d output_stall=%0d",
                         output_word, cycle_count, input_stall_cycles, output_stall_cycles);
            end
            begin
                repeat (2000) @(posedge clk);
                $fatal(1, "pool executor timeout");
            end
        join_any
        disable completion_or_timeout;
        $finish;
    end
endmodule
