`timescale 1ns/1ps

module camus_history_datamover_bridge_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_history = 1'b0;

    logic enc_cmd_valid = 1'b0;
    logic enc_cmd_ready;
    logic [71:0] enc_cmd_data = '0;
    logic enc_status_valid;
    logic enc_status_ready = 1'b1;
    logic [7:0] enc_status_data;
    logic enc_data_valid = 1'b0;
    logic enc_data_ready;
    logic [127:0] enc_data = '0;
    logic [15:0] enc_keep = 16'hffff;
    logic enc_last = 1'b0;

    logic dec_cmd_valid = 1'b0;
    logic dec_cmd_ready;
    logic [71:0] dec_cmd_data = '0;
    logic dec_status_valid;
    logic dec_status_ready = 1'b1;
    logic [7:0] dec_status_data;
    logic dec_data_valid;
    logic dec_data_ready;
    logic [127:0] dec_data;
    logic [15:0] dec_keep;
    logic dec_last;

    logic [1:0] history_count;
    logic busy, error;
    integer cycle = 0;
    integer output_word = 0;
    localparam integer GROUPS_PER_FRAME = 4;
    localparam integer DEPTH = 16;
    logic [63:0] expected [0:23];

    always #5 clk = ~clk;
    assign dec_data_ready = (cycle % 5) != 2;
    always @(posedge clk)
        if (!rst) cycle <= cycle + 1;

    camus_history_datamover_bridge #(
        .DEPTH(DEPTH), .GROUPS_PER_FRAME(GROUPS_PER_FRAME)
    ) dut (.*);

    task automatic write_frame(input integer base, input logic [3:0] tag);
        integer beat;
        begin
            @(negedge clk);
            enc_cmd_data = '0;
            enc_cmd_data[67:64] = tag;
            enc_cmd_data[22:0] = DEPTH * 8;
            enc_cmd_valid = 1'b1;
            while (!enc_cmd_ready) @(negedge clk);
            @(negedge clk);
            enc_cmd_valid = 1'b0;

            for (beat = 0; beat < DEPTH / 2; beat = beat + 1) begin
                enc_data = {64'(base + beat*2 + 1), 64'(base + beat*2)};
                enc_last = beat == DEPTH / 2 - 1;
                enc_data_valid = 1'b1;
                while (!enc_data_ready) @(negedge clk);
                @(negedge clk);
            end
            enc_data_valid = 1'b0;
            enc_last = 1'b0;
            wait (enc_status_valid);
            if (enc_status_data !== {1'b1, 3'b000, tag})
                $fatal(1, "encoder status mismatch %h", enc_status_data);
            wait (!busy);
            @(negedge clk);
        end
    endtask

    task automatic read_strip(
        input integer first_pixel,
        input integer pixels,
        input logic [3:0] tag,
        input integer old_base,
        input integer previous_base,
        input integer current_base
    );
        integer words_expected;
        integer pixel;
        integer source;
        integer group_index;
        integer local_word;
        begin
            words_expected = pixels * GROUPS_PER_FRAME * 3;
            for (local_word = 0; local_word < words_expected; local_word = local_word + 1) begin
                pixel = first_pixel + local_word / (GROUPS_PER_FRAME * 3);
                source = (local_word % (GROUPS_PER_FRAME * 3)) / GROUPS_PER_FRAME;
                group_index = local_word % GROUPS_PER_FRAME;
                expected[local_word] = source == 0
                    ? old_base + pixel * GROUPS_PER_FRAME + group_index
                    : source == 1
                        ? previous_base + pixel * GROUPS_PER_FRAME + group_index
                        : current_base + pixel * GROUPS_PER_FRAME + group_index;
            end
            output_word = 0;

            @(negedge clk);
            dec_cmd_data = '0;
            dec_cmd_data[67:64] = tag;
            dec_cmd_data[63:32] = first_pixel * GROUPS_PER_FRAME * 3 * 8;
            dec_cmd_data[22:0] = pixels * GROUPS_PER_FRAME * 3 * 8;
            dec_cmd_valid = 1'b1;
            while (!dec_cmd_ready) @(negedge clk);
            @(negedge clk);
            dec_cmd_valid = 1'b0;

            while (output_word < words_expected) begin
                @(posedge clk);
                if (dec_data_valid && dec_data_ready) begin
                    if (dec_data[63:0] !== expected[output_word])
                        $fatal(1, "history word %0d got=%h expected=%h",
                               output_word, dec_data[63:0], expected[output_word]);
                    output_word = output_word + 1;
                    if (output_word < words_expected) begin
                        if (dec_keep[15:8] !== 8'hff
                                || dec_data[127:64] !== expected[output_word])
                            $fatal(1, "history upper word %0d got=%h expected=%h keep=%h",
                                   output_word, dec_data[127:64], expected[output_word], dec_keep);
                        output_word = output_word + 1;
                    end else if (dec_keep[15:8] !== 8'h00) begin
                        $fatal(1, "history final keep mismatch %h", dec_keep);
                    end
                    if (dec_last != (output_word == words_expected))
                        $fatal(1, "history last mismatch word=%0d", output_word);
                end
            end
            wait (dec_status_valid);
            if (dec_status_data !== {1'b1, 3'b000, tag})
                $fatal(1, "decoder status mismatch %h", dec_status_data);
            wait (!busy);
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        write_frame(100, 4'h1);
        if (dut.u_history.g_history_bank[0].u_bank.memory[0] !== 64'd100
                || dut.u_history.g_history_bank[0].u_bank.memory[3] !== 64'd103
                || dut.u_history.g_history_bank[0].u_bank.memory[4] !== 64'd104
                || dut.u_history.g_history_bank[0].u_bank.memory[15] !== 64'd115)
            $fatal(1, "history frame write order mismatch %0d %0d %0d %0d",
                   dut.u_history.g_history_bank[0].u_bank.memory[0],
                   dut.u_history.g_history_bank[0].u_bank.memory[3],
                   dut.u_history.g_history_bank[0].u_bank.memory[4],
                   dut.u_history.g_history_bank[0].u_bank.memory[15]);
        read_strip(0, 2, 4'h2, 100, 100, 100);
        read_strip(2, 2, 4'h3, 100, 100, 100);

        write_frame(200, 4'h4);
        read_strip(0, 2, 4'h5, 100, 100, 200);

        write_frame(300, 4'h6);
        read_strip(2, 2, 4'h7, 100, 200, 300);

        if (error || busy || history_count != 2)
            $fatal(1, "bridge summary error=%b busy=%b count=%0d enc_state=%0d dec_state=%0d enc_sts=%b dec_sts=%b",
                   error, busy, history_count, dut.enc_state, dut.dec_state,
                   enc_status_valid, dec_status_valid);
        $display("PASS camus_history_datamover_bridge frames=3 strips=4 history_count=%0d cycles=%0d",
                 history_count, cycle);
        $finish;
    end
endmodule
