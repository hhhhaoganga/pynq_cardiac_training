`timescale 1ns/1ps

module camus_concat_rescale_axis_tb;
    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    logic start;
    logic [5:0] a_channels, b_channels;
    logic signed [31:0] a_multiplier, b_multiplier;
    logic signed [6:0] a_shift, b_shift;
    logic a_valid, a_ready, a_last;
    logic [63:0] a_data;
    logic b_valid, b_ready, b_last;
    logic [63:0] b_data;
    logic m_valid, m_ready, m_last, pixel_done, busy, error;
    logic [63:0] m_data;
    integer outputs;
    logic finished = 0;

    camus_concat_rescale_axis dut (
        .clk(clk), .rst(rst), .start(start),
        .a_channels(a_channels), .b_channels(b_channels),
        .a_multiplier(a_multiplier), .a_shift(a_shift),
        .b_multiplier(b_multiplier), .b_shift(b_shift),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(a_data),
        .a_last_group(a_last), .b_valid(b_valid), .b_ready(b_ready),
        .b_data(b_data), .b_last_group(b_last),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),
        .m_last_group(m_last), .pixel_done(pixel_done),
        .busy(busy), .error(error)
    );

    initial begin
        #5000;
        if (!finished)
            $fatal(1, "concat timeout state=%0d busy=%0d product_valid=%0d m_valid=%0d",
                dut.state, busy, dut.product_valid, m_valid);
    end

    initial begin
        start = 0;
        a_channels = 4;
        b_channels = 4;
        // fixed_ratio(1.0) = 2^29 with shift 29.
        a_multiplier = 32'sd536870912;
        b_multiplier = 32'sd536870912;
        a_shift = 29;
        b_shift = 29;
        a_valid = 0;
        b_valid = 0;
        a_last = 0;
        b_last = 0;
        a_data = 64'h0000000004030201;
        b_data = 64'h000000000e0d0c0b;
        m_ready = 1;

        repeat (5) @(posedge clk);
        rst = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        a_valid = 1;
        b_valid = 1;
        a_last = 1;
        b_last = 1;
        while (!a_ready || !b_ready) @(negedge clk);
        @(negedge clk);
        a_valid = 0;
        b_valid = 0;
        a_last = 0;
        b_last = 0;

        outputs = 0;
        while (!pixel_done) begin
            @(posedge clk);
            if (m_valid && m_ready) begin
                if (m_data !== 64'h0e0d0c0b04030201)
                    $fatal(1, "concat 4+4 got=%h", m_data);
                if (!m_last)
                    $fatal(1, "concat 4+4 missing last");
                outputs = outputs + 1;
            end
        end
        if (outputs != 1 || error)
            $fatal(1, "concat outputs=%0d error=%0d", outputs, error);
        $display("PASS camus_concat_rescale_axis dense_4_plus_4");
        finished = 1;
        $finish;
    end
endmodule
