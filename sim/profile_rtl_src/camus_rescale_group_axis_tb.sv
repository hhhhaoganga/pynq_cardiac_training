`timescale 1ns/1ps
module camus_rescale_group_axis_tb;
    logic clk=0,rst=1,s_valid=0,s_ready,s_last=0,m_valid,m_ready,m_last;
    logic [63:0] s_data,m_data;
    logic signed [31:0] low_multiplier=536870912,high_multiplier=536870912;
    logic signed [6:0] low_shift=29,high_shift=29;
    logic [3:0] split_lane=4;
    integer sent=0,received=0,cycle=0;
    always #5 clk=~clk;
    assign m_ready=(cycle%7)!=3;
    camus_rescale_group_axis dut(.*);
    always @(posedge clk) begin
        if(!rst) cycle<=cycle+1;
        if(m_valid&&m_ready) begin
            if(m_data!=={8{received[7:0]}}||m_last!=(received==31))
                $fatal(1,"rescale mismatch index=%0d data=%h last=%b",received,m_data,m_last);
            received<=received+1;
        end
    end
    initial begin
        repeat(4) @(posedge clk); @(negedge clk);rst=0;
        while(sent<32) begin
            s_valid=1;s_data={8{sent[7:0]}};s_last=sent==31;
            @(posedge clk); if(s_ready) sent=sent+1;
            @(negedge clk);
        end
        s_valid=0;s_last=0;
        wait(received==32);@(negedge clk);
        $display("PASS camus_rescale_group_axis groups=32 cycles=%0d",cycle);
        $finish;
    end
endmodule
