`timescale 1ns/1ps

module camus_stream_ops_tb;
    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    logic pool_start, pool_s_valid, pool_s_ready, pool_s_last;
    logic [63:0] pool_s_data;
    logic pool_m_valid, pool_m_ready, pool_m_last;
    logic [63:0] pool_m_data;
    logic pool_busy, pool_done, pool_error;

    camus_pool2x2_axis #(.MAX_WIDTH(8), .MAX_GROUPS(2)) u_pool (
        .clk(clk), .rst(rst), .start(pool_start),
        .width(9'd4), .height(9'd4), .groups(3'd1),
        .s_valid(pool_s_valid), .s_ready(pool_s_ready),
        .s_data(pool_s_data), .s_last(pool_s_last),
        .m_valid(pool_m_valid), .m_ready(pool_m_ready),
        .m_data(pool_m_data), .m_last(pool_m_last),
        .busy(pool_busy), .done(pool_done), .error(pool_error)
    );

    logic hist_clear, hist_write_start, hist_write_valid, hist_write_ready;
    logic [63:0] hist_write_data;
    logic hist_write_last, hist_write_done;
    logic hist_start, hist_valid, hist_ready, hist_last, hist_done;
    logic [63:0] hist_data;
    logic [1:0] hist_count;
    logic hist_error;

    camus_bottleneck_history #(.DEPTH(8)) u_history (
        .clk(clk), .rst(rst), .clear_history(hist_clear),
        .write_start(hist_write_start), .write_valid(hist_write_valid),
        .write_ready(hist_write_ready), .write_data(hist_write_data),
        .write_last(hist_write_last), .write_done(hist_write_done),
        .temporal_start(hist_start), .temporal_first_pixel(16'd0),
        .pixels(16'd2), .groups_per_frame(3'd1),
        .temporal_valid(hist_valid), .temporal_ready(hist_ready),
        .temporal_data(hist_data), .temporal_last(hist_last),
        .temporal_done(hist_done), .history_count(hist_count), .error(hist_error)
    );

    logic arg_s_valid, arg_s_ready, arg_s_last;
    logic [31:0] arg_logits;
    logic arg_m_valid, arg_m_ready, arg_m_last;
    logic [7:0] arg_class;

    camus_argmax4_axis u_argmax (
        .clk(clk), .rst(rst), .s_valid(arg_s_valid), .s_ready(arg_s_ready),
        .s_logits(arg_logits), .s_last(arg_s_last),
        .m_valid(arg_m_valid), .m_ready(arg_m_ready),
        .m_class(arg_class), .m_last(arg_m_last)
    );

    logic addr_start, addr_valid, addr_ready, addr_skip, addr_last;
    logic [19:0] addr_word;
    logic [2:0] addr_group;
    logic addr_busy, addr_done, addr_error;

    camus_nearest_concat_addrgen u_addr (
        .clk(clk), .rst(rst), .start(addr_start),
        .low_width(9'd2), .low_height(9'd2),
        .project_groups(3'd1), .skip_groups(3'd1),
        .request_valid(addr_valid), .request_ready(addr_ready),
        .request_skip(addr_skip), .request_word_address(addr_word),
        .output_group(addr_group), .output_last(addr_last),
        .busy(addr_busy), .done(addr_done), .error(addr_error)
    );

    integer i, lane, output_index;
    integer hx, hy, source;
    reg [63:0] expected_word;

    task automatic pulse(input integer which);
        begin
            @(negedge clk);
            case (which)
                0: pool_start = 1;
                1: hist_write_start = 1;
                2: hist_start = 1;
                3: addr_start = 1;
            endcase
            @(negedge clk);
            pool_start = 0;
            hist_write_start = 0;
            hist_start = 0;
            addr_start = 0;
        end
    endtask

    task automatic write_history_frame(input integer base_value);
        begin
            pulse(1);
            for (i = 0; i < 2; i = i + 1) begin
                @(negedge clk);
                hist_write_valid = 1;
                hist_write_data = base_value + i;
                hist_write_last = i == 1;
                while (!hist_write_ready) @(negedge clk);
            end
            @(negedge clk);
            hist_write_valid = 0;
            hist_write_last = 0;
            wait(hist_write_done);
        end
    endtask

    task automatic check_history(
        input integer old_base,
        input integer previous_base,
        input integer current_base
    );
        integer beat;
        integer pixel;
        integer selector;
        integer expected;
        begin
            beat = 0;
            pulse(2);
            while (beat < 6) begin
                @(posedge clk);
                if (hist_valid && hist_ready) begin
                    pixel = beat / 3;
                    selector = beat % 3;
                    expected = selector == 0 ? old_base + pixel
                        : selector == 1 ? previous_base + pixel : current_base + pixel;
                    if (hist_data !== expected)
                        $fatal(1, "history beat=%0d got=%h expected=%h", beat, hist_data, expected);
                    if (hist_last != (beat == 5))
                        $fatal(1, "history last mismatch beat=%0d", beat);
                    beat = beat + 1;
                end
            end
            wait(hist_done);
        end
    endtask

    initial begin
        pool_start = 0;
        pool_s_valid = 0;
        pool_s_data = 0;
        pool_s_last = 0;
        pool_m_ready = 1;
        hist_clear = 0;
        hist_write_start = 0;
        hist_write_valid = 0;
        hist_write_data = 0;
        hist_write_last = 0;
        hist_start = 0;
        hist_ready = 1;
        arg_s_valid = 0;
        arg_s_last = 0;
        arg_logits = 0;
        arg_m_ready = 1;
        addr_start = 0;
        addr_ready = 1;

        repeat (5) @(posedge clk);
        rst = 0;

        // Pool: monotonic raster values make each 2x2 result its bottom-right word.
        pulse(0);
        output_index = 0;
        fork
            begin
                integer input_index;
                for (input_index = 0; input_index < 16; input_index = input_index + 1) begin
                    @(negedge clk);
                    pool_s_valid = 1;
                    pool_s_last = input_index == 15;
                    for (lane = 0; lane < 8; lane = lane + 1)
                        pool_s_data[lane*8 +: 8] = input_index*8 + lane;
                    while (!pool_s_ready) @(negedge clk);
                end
                @(negedge clk);
                pool_s_valid = 0;
                pool_s_last = 0;
            end
            begin
                integer expected_pixel;
                while (output_index < 4) begin
                    @(posedge clk);
                    if (pool_m_valid && pool_m_ready) begin
                        case (output_index)
                            0: expected_pixel = 5;
                            1: expected_pixel = 7;
                            2: expected_pixel = 13;
                            default: expected_pixel = 15;
                        endcase
                        for (lane = 0; lane < 8; lane = lane + 1)
                            expected_word[lane*8 +: 8] = expected_pixel*8 + lane;
                        if (pool_m_data !== expected_word)
                            $fatal(1, "pool output=%0d got=%h expected=%h",
                                output_index, pool_m_data, expected_word);
                        if (pool_m_last != (output_index == 3))
                            $fatal(1, "pool last mismatch output=%0d", output_index);
                        output_index = output_index + 1;
                    end
                end
            end
        join
        wait(pool_done);
        if (pool_error) $fatal(1, "pool reported error");

        write_history_frame(100);
        check_history(100, 100, 100);
        write_history_frame(200);
        check_history(100, 100, 200);
        write_history_frame(300);
        check_history(100, 200, 300);
        if (hist_error || hist_count != 2)
            $fatal(1, "history state error count=%0d error=%0d", hist_count, hist_error);

        // Argmax includes negative values and a lowest-index tie.
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge clk);
            arg_s_valid = 1;
            arg_s_last = i == 3;
            case (i)
                0: arg_logits = {8'sd4, 8'sd3, 8'sd2, 8'sd1};
                1: arg_logits = {-8'sd5, 8'sd20, 8'sd1, 8'sd2};
                2: arg_logits = {8'sd7, 8'sd7, 8'sd7, 8'sd7};
                default: arg_logits = {8'sd0, -8'sd1, -8'sd2, -8'sd3};
            endcase
            @(posedge clk);
            #1;
            if (!arg_m_valid) $fatal(1, "argmax missing output %0d", i);
            case (i)
                0: if (arg_class != 3) $fatal(1, "argmax case0 got=%0d", arg_class);
                1: if (arg_class != 2) $fatal(1, "argmax case1 got=%0d", arg_class);
                2: if (arg_class != 0) $fatal(1, "argmax tie got=%0d", arg_class);
                3: if (arg_class != 3) $fatal(1, "argmax case3 got=%0d", arg_class);
            endcase
        end
        @(negedge clk);
        arg_s_valid = 0;

        pulse(3);
        hx = 0;
        hy = 0;
        source = 0;
        while (addr_busy) begin
            @(posedge clk);
            if (addr_valid && addr_ready) begin
                if (addr_skip != source)
                    $fatal(1, "addr source mismatch x=%0d y=%0d", hx, hy);
                if (!source && addr_word != ((hy >> 1)*2 + (hx >> 1)))
                    $fatal(1, "project addr mismatch x=%0d y=%0d got=%0d", hx, hy, addr_word);
                if (source && addr_word != (hy*4 + hx))
                    $fatal(1, "skip addr mismatch x=%0d y=%0d got=%0d", hx, hy, addr_word);
                if (addr_last != (source && hx == 3 && hy == 3))
                    $fatal(1, "addr last mismatch x=%0d y=%0d source=%0d", hx, hy, source);
                if (source) begin
                    source = 0;
                    if (hx == 3) begin
                        hx = 0;
                        hy = hy + 1;
                    end else hx = hx + 1;
                end else source = 1;
            end
        end
        wait(addr_done);
        if (addr_error) $fatal(1, "address generator reported error");

        $display("PASS camus_stream_ops pool=4 history=3frames argmax=4 addr=32");
        $finish;
    end
endmodule
