`timescale 1ns/1ps

module camus_compact_input_datamover_executor_tb #(
    parameter integer WIDTH=31,
    parameter integer HEIGHT=1
);
    localparam integer PIXELS=WIDTH*HEIGHT;
    localparam integer INPUT_BEATS=(PIXELS+15)/16;
    localparam [15:0] LAST_INPUT_KEEP=PIXELS%16==0
        ?16'hffff:(16'hffff>>(16-PIXELS%16));
    localparam [15:0] LAST_OUTPUT_KEEP=PIXELS%2==0?16'hffff:16'h00ff;
    logic clk=0,rst=1,start=0;
    logic [31:0] input_base_bytes=32'h0100_0000;
    logic [31:0] output_base_bytes=32'h0200_0000;
    logic [8:0] width=WIDTH,height=HEIGHT;
    logic [3:0] command_tag=4'hc;
    logic [31:0] watchdog_limit=PIXELS*3+1000;
    logic m_axis_mm2s_cmd_tvalid,m_axis_mm2s_cmd_tready=1;
    logic [71:0] m_axis_mm2s_cmd_tdata;
    logic s_axis_mm2s_sts_tvalid=0,s_axis_mm2s_sts_tready;
    logic [7:0] s_axis_mm2s_sts_tdata=0;
    logic s_axis_mm2s_tvalid,s_axis_mm2s_tready;
    logic [127:0] s_axis_mm2s_tdata;
    logic [15:0] s_axis_mm2s_tkeep;
    logic s_axis_mm2s_tlast;
    logic m_axis_s2mm_cmd_tvalid,m_axis_s2mm_cmd_tready=1;
    logic [71:0] m_axis_s2mm_cmd_tdata;
    logic s_axis_s2mm_sts_tvalid=0,s_axis_s2mm_sts_tready;
    logic [7:0] s_axis_s2mm_sts_tdata=0;
    logic m_axis_s2mm_tvalid,m_axis_s2mm_tready;
    logic [127:0] m_axis_s2mm_tdata;
    logic [15:0] m_axis_s2mm_tkeep;
    logic m_axis_s2mm_tlast;
    logic busy,done,error;
    logic [63:0] cycle_count;
    logic [31:0] input_stall_cycles,output_stall_cycles;
    integer cycle=0,input_beat=0,output_word=0;
    integer mm_status_delay=0,s2_status_delay=0,i;
    logic mm_active=0,s2_active=0;

    always #5 clk=~clk;
    assign s_axis_mm2s_tvalid=mm_active&&(cycle%5!=1);
    always_comb begin
        s_axis_mm2s_tdata=0;
        for(i=0;i<16;i=i+1)
            s_axis_mm2s_tdata[i*8 +: 8]=(input_beat*16+i)&8'hff;
    end
    assign s_axis_mm2s_tkeep=input_beat==INPUT_BEATS-1
        ?LAST_INPUT_KEEP:16'hffff;
    assign s_axis_mm2s_tlast=mm_active&&input_beat==INPUT_BEATS-1;
    assign m_axis_s2mm_tready=(cycle%7)!=3;

    camus_compact_input_datamover_executor dut(.*);

    always @(posedge clk) begin
        if(!rst) cycle<=cycle+1;
        if(m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready) begin
            if(m_axis_mm2s_cmd_tdata[63:32]!==input_base_bytes
                    ||m_axis_mm2s_cmd_tdata[22:0]!==PIXELS
                    ||m_axis_mm2s_cmd_tdata[67:64]!==command_tag)
                $fatal(1,"bad compact MM2S command %h",m_axis_mm2s_cmd_tdata);
            mm_active<=1;input_beat<=0;
        end
        if(s_axis_mm2s_tvalid&&s_axis_mm2s_tready) begin
            if(input_beat==INPUT_BEATS-1) begin
                mm_active<=0;mm_status_delay<=5;
            end
            else input_beat<=input_beat+1;
        end
        if(mm_status_delay>0) begin
            mm_status_delay<=mm_status_delay-1;
            if(mm_status_delay==1) begin
                s_axis_mm2s_sts_tvalid<=1;
                s_axis_mm2s_sts_tdata<={1'b1,3'b000,command_tag};
            end
        end else if(s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready)
            s_axis_mm2s_sts_tvalid<=0;

        if(m_axis_s2mm_cmd_tvalid&&m_axis_s2mm_cmd_tready) begin
            if(m_axis_s2mm_cmd_tdata[63:32]!==output_base_bytes
                    ||m_axis_s2mm_cmd_tdata[22:0]!==PIXELS*8
                    ||m_axis_s2mm_cmd_tdata[67:64]!==command_tag)
                $fatal(1,"bad padded S2MM command %h",m_axis_s2mm_cmd_tdata);
            s2_active<=1;
        end
        if(m_axis_s2mm_tvalid&&m_axis_s2mm_tready) begin
            if(!s2_active) $fatal(1,"output before S2MM command");
            if(m_axis_s2mm_tdata[63:8]!==56'd0
                    ||m_axis_s2mm_tdata[7:0]!==output_word[7:0])
                $fatal(1,"lower mismatch word=%0d data=%h",output_word,
                    m_axis_s2mm_tdata[63:0]);
            output_word<=output_word+1;
            if(output_word+1<PIXELS) begin
                if(m_axis_s2mm_tdata[127:72]!==56'd0
                        ||m_axis_s2mm_tdata[71:64]
                            !==((output_word+1)&8'hff))
                    $fatal(1,"upper mismatch word=%0d data=%h",output_word+1,
                        m_axis_s2mm_tdata[127:64]);
                output_word<=output_word+2;
            end
            if(m_axis_s2mm_tlast) begin
                if(m_axis_s2mm_tkeep!==LAST_OUTPUT_KEEP
                        ||output_word
                            +((LAST_OUTPUT_KEEP==16'hffff)?2:1)!=PIXELS)
                    $fatal(1,"bad final packet keep=%h words=%0d",
                        m_axis_s2mm_tkeep,output_word);
                s2_active<=0;s2_status_delay<=7;
            end else if(m_axis_s2mm_tkeep!==16'hffff)
                $fatal(1,"bad non-final keep=%h",m_axis_s2mm_tkeep);
        end
        if(s2_status_delay>0) begin
            s2_status_delay<=s2_status_delay-1;
            if(s2_status_delay==1) begin
                s_axis_s2mm_sts_tvalid<=1;
                s_axis_s2mm_sts_tdata<={1'b1,3'b000,command_tag};
            end
        end else if(s_axis_s2mm_sts_tvalid&&s_axis_s2mm_sts_tready)
            s_axis_s2mm_sts_tvalid<=0;
    end

    initial begin
        repeat(5) @(posedge clk);@(negedge clk);rst=0;start=1;
        @(negedge clk);start=0;
        fork : finish_or_timeout
            begin
                wait(done);@(negedge clk);
                if(error||busy||s2_active||output_word!=PIXELS)
                    $fatal(1,"summary error=%b busy=%b s2=%b words=%0d",
                        error,busy,s2_active,output_word);
                $display("PASS camus_compact_input pixels=%0d cycles=%0d stalls=%0d/%0d",
                    PIXELS,cycle_count,input_stall_cycles,output_stall_cycles);
            end
            begin repeat(PIXELS*3+1000) @(posedge clk);
                $fatal(1,"compact input timeout");
            end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
