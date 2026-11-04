`timescale 1ns/1ps

module camus_lcc_full_frame_tb;
    localparam integer W=256,H=256,N=W*H;
    localparam logic [31:0] MASK_BASE=32'h0001_0000;
    localparam logic [31:0] LABEL_BASE=32'h0003_0000;
    logic clk=0,rst=1,start=0;
    logic [8:0] width=W,height=H;
    logic [3:0] command_tag=4'h9;
    logic [31:0] watchdog_limit=32'd5000000;
    logic m_axis_mm2s_cmd_tvalid,m_axis_mm2s_cmd_tready;
    logic [71:0] m_axis_mm2s_cmd_tdata;
    logic s_axis_mm2s_sts_tvalid,s_axis_mm2s_sts_tready;
    logic [7:0] s_axis_mm2s_sts_tdata;
    logic s_axis_mm2s_tvalid,s_axis_mm2s_tready;
    logic [127:0] s_axis_mm2s_tdata;
    logic [15:0] s_axis_mm2s_tkeep;
    logic s_axis_mm2s_tlast;
    logic m_axis_s2mm_cmd_tvalid,m_axis_s2mm_cmd_tready;
    logic [71:0] m_axis_s2mm_cmd_tdata;
    logic s_axis_s2mm_sts_tvalid,s_axis_s2mm_sts_tready;
    logic [7:0] s_axis_s2mm_sts_tdata;
    logic m_axis_s2mm_tvalid,m_axis_s2mm_tready;
    logic [127:0] m_axis_s2mm_tdata;
    logic [15:0] m_axis_s2mm_tkeep;
    logic m_axis_s2mm_tlast;
    logic busy,done,error,overflow;
    logic [63:0] cycle_count;
    logic [15:0] labels_used;
    logic [4:0] debug_wait;
    logic [50:0] area_counts;
    logic ddr_error;
    logic enc_mm2s_cmd_ready,enc_mm2s_sts_valid,enc_mm2s_valid;
    logic [7:0] enc_mm2s_sts_data;
    logic [127:0] enc_mm2s_data;
    logic [15:0] enc_mm2s_keep;
    logic enc_mm2s_last,enc_s2mm_cmd_ready,enc_s2mm_sts_valid,enc_s2mm_ready;
    logic [7:0] enc_s2mm_sts_data;
    logic [7:0] expected[0:N-1];
    string input_path,expected_path;
    integer input_fd,expected_fd,value,index,mismatches,first_mismatch;

    always #5 clk=~clk;

    camus_lcc_datamover_executor dut(
        .clk,.rst,.start,.mask_base_bytes(MASK_BASE),.label_base_bytes(LABEL_BASE),
        .width,.height,.command_tag,.watchdog_limit,.*);

    camus_dual_datamover_ddr_model #(.MEM_BYTES(524288)) ddr(
        .clk,.rst,
        .enc_mm2s_cmd_valid(1'b0),.enc_mm2s_cmd_ready,
        .enc_mm2s_cmd_data(72'd0),.enc_mm2s_sts_valid,
        .enc_mm2s_sts_ready(1'b1),.enc_mm2s_sts_data,
        .enc_mm2s_valid,.enc_mm2s_ready(1'b1),.enc_mm2s_data,
        .enc_mm2s_keep,.enc_mm2s_last,
        .enc_s2mm_cmd_valid(1'b0),.enc_s2mm_cmd_ready,
        .enc_s2mm_cmd_data(72'd0),.enc_s2mm_sts_valid,
        .enc_s2mm_sts_ready(1'b1),.enc_s2mm_sts_data,
        .enc_s2mm_valid(1'b0),.enc_s2mm_ready,
        .enc_s2mm_data(128'd0),.enc_s2mm_keep(16'd0),.enc_s2mm_last(1'b0),
        .dec_mm2s_cmd_valid(m_axis_mm2s_cmd_tvalid),
        .dec_mm2s_cmd_ready(m_axis_mm2s_cmd_tready),
        .dec_mm2s_cmd_data(m_axis_mm2s_cmd_tdata),
        .dec_mm2s_sts_valid(s_axis_mm2s_sts_tvalid),
        .dec_mm2s_sts_ready(s_axis_mm2s_sts_tready),
        .dec_mm2s_sts_data(s_axis_mm2s_sts_tdata),
        .dec_mm2s_valid(s_axis_mm2s_tvalid),.dec_mm2s_ready(s_axis_mm2s_tready),
        .dec_mm2s_data(s_axis_mm2s_tdata),.dec_mm2s_keep(s_axis_mm2s_tkeep),
        .dec_mm2s_last(s_axis_mm2s_tlast),
        .dec_s2mm_cmd_valid(m_axis_s2mm_cmd_tvalid),
        .dec_s2mm_cmd_ready(m_axis_s2mm_cmd_tready),
        .dec_s2mm_cmd_data(m_axis_s2mm_cmd_tdata),
        .dec_s2mm_sts_valid(s_axis_s2mm_sts_tvalid),
        .dec_s2mm_sts_ready(s_axis_s2mm_sts_tready),
        .dec_s2mm_sts_data(s_axis_s2mm_sts_tdata),
        .dec_s2mm_valid(m_axis_s2mm_tvalid),.dec_s2mm_ready(m_axis_s2mm_tready),
        .dec_s2mm_data(m_axis_s2mm_tdata),.dec_s2mm_keep(m_axis_s2mm_tkeep),
        .dec_s2mm_last(m_axis_s2mm_tlast),.error(ddr_error));

    initial begin
        if(!$value$plusargs("INPUT_FILE=%s",input_path)
                || !$value$plusargs("EXPECTED_FILE=%s",expected_path))
            $fatal(1,"missing LCC golden file plusargs");
        input_fd=$fopen(input_path,"rb");
        expected_fd=$fopen(expected_path,"rb");
        if(input_fd==0 || expected_fd==0)
            $fatal(1,"cannot open LCC golden files");
        for(index=0;index<N;index=index+1) begin
            value=$fgetc(input_fd);
            if(value<0) $fatal(1,"short input golden file at pixel=%0d",index);
            ddr.mem[MASK_BASE+index]=value[7:0];
            value=$fgetc(expected_fd);
            if(value<0) $fatal(1,"short expected golden file at pixel=%0d",index);
            expected[index]=value[7:0];
        end
        $fclose(input_fd);
        $fclose(expected_fd);
    end

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); rst=0; start=1;
        @(negedge clk); start=0;
        fork : finish_or_timeout
            begin
                wait(done);
                @(negedge clk);
                if(error || overflow || ddr_error)
                    $fatal(1,"summary error=%b overflow=%b ddr=%b labels=%0d cycles=%0d",
                        error,overflow,ddr_error,labels_used,cycle_count);
                mismatches=0;
                first_mismatch=-1;
                for(index=0;index<N;index=index+1)
                    if(ddr.mem[MASK_BASE+index]!==expected[index]) begin
                        mismatches=mismatches+1;
                        if(first_mismatch<0) first_mismatch=index;
                    end
                if(mismatches!=0)
                    $fatal(1,"LCC full-frame mismatch count=%0d first=%0d got=%0d expected=%0d",
                        mismatches,first_mismatch,ddr.mem[MASK_BASE+first_mismatch],expected[first_mismatch]);
                $display("PASS camus_lcc_full_frame pixels=%0d labels=%0d cycles=%0d areas=%h",
                    N,labels_used,cycle_count,area_counts);
            end
            begin
                repeat(10000000) @(posedge clk);
                $fatal(1,"LCC full-frame timeout state=%0d core=%0d labels=%0d masks=%0d",
                    dut.state,dut.u_core.state,dut.label_out_count,dut.mask_out_count);
            end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
