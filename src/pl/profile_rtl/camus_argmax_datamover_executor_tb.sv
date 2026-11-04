`timescale 1ns/1ps

module camus_argmax_datamover_executor_tb;
    localparam integer WIDTH=5;
    localparam integer HEIGHT=3;
    localparam integer PIXELS=WIDTH*HEIGHT;
    logic clk=0,rst=1,start=0;
    logic [31:0] input_base_bytes=32'h0010_0000,mask_base_bytes=32'h0020_0000;
    logic [8:0] width=WIDTH,height=HEIGHT;
    logic [3:0] command_tag=4'hb;
    logic [31:0] watchdog_limit=10000;
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
    logic [63:0] input_words[0:PIXELS-1];
    integer cycle=0,input_beat=0,mm_status_delay=0,s2_status_delay=0;
    logic mm_active=0,s2_active=0;

    always #5 clk=~clk;
    assign s_axis_mm2s_tvalid=mm_active;
    assign s_axis_mm2s_tdata={
        input_beat*2+1<PIXELS ? input_words[input_beat*2+1] : 64'd0,
        input_words[input_beat*2]};
    assign s_axis_mm2s_tkeep=input_beat==(PIXELS/2) ? 16'h00ff : 16'hffff;
    assign s_axis_mm2s_tlast=mm_active&&input_beat==PIXELS/2;
    assign m_axis_s2mm_tready=(cycle%7)!=2;

    camus_argmax_datamover_executor dut(.*);

    function automatic [31:0] logits(input integer pixel);
        case(pixel%4)
            0: logits={8'sd1,8'sd2,8'sd3,8'sd20};
            1: logits={-8'sd5,8'sd1,8'sd30,8'sd2};
            2: logits={8'sd7,8'sd7,8'sd7,8'sd7};
            default: logits={8'sd40,8'sd3,8'sd2,8'sd1};
        endcase
    endfunction

    function automatic [7:0] expected_class(input integer pixel);
        case(pixel%4)
            0: expected_class=0;
            1: expected_class=1;
            2: expected_class=0;
            default: expected_class=3;
        endcase
    endfunction

    integer i;
    initial begin
        for(i=0;i<PIXELS;i=i+1) input_words[i]={32'd0,logits(i)};
    end

    always @(posedge clk) begin
        if(!rst) cycle<=cycle+1;
        if(m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready) begin
            if(m_axis_mm2s_cmd_tdata[63:32]!==input_base_bytes
                    ||m_axis_mm2s_cmd_tdata[22:0]!==PIXELS*8
                    ||m_axis_mm2s_cmd_tdata[67:64]!==command_tag)
                $fatal(1,"bad MM2S command %h",m_axis_mm2s_cmd_tdata);
            mm_active<=1;input_beat<=0;
        end
        if(s_axis_mm2s_tvalid&&s_axis_mm2s_tready) begin
            if(input_beat==PIXELS/2) begin mm_active<=0;mm_status_delay<=4;end
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
            if(m_axis_s2mm_cmd_tdata[63:32]!==mask_base_bytes
                    ||m_axis_s2mm_cmd_tdata[22:0]!==PIXELS
                    ||m_axis_s2mm_cmd_tdata[67:64]!==command_tag)
                $fatal(1,"bad S2MM command %h",m_axis_s2mm_cmd_tdata);
            s2_active<=1;
        end
        if(m_axis_s2mm_tvalid&&m_axis_s2mm_tready) begin
            if(!s2_active||!m_axis_s2mm_tlast||m_axis_s2mm_tkeep!==16'h7fff)
                $fatal(1,"bad mask packet active=%b last=%b keep=%h",
                    s2_active,m_axis_s2mm_tlast,m_axis_s2mm_tkeep);
            for(i=0;i<PIXELS;i=i+1)
                if(m_axis_s2mm_tdata[i*8 +:8]!==expected_class(i))
                    $fatal(1,"mask mismatch pixel=%0d got=%0d",i,
                        m_axis_s2mm_tdata[i*8 +:8]);
            s2_active<=0;s2_status_delay<=6;
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
                if(error||busy||s2_active)
                    $fatal(1,"summary error=%b busy=%b s2=%b",error,busy,s2_active);
                $display("PASS camus_argmax_datamover_executor pixels=%0d cycles=%0d",
                    PIXELS,cycle_count);
            end
            begin repeat(2000) @(posedge clk);$fatal(1,"argmax executor timeout");end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
