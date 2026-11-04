`timescale 1ns/1ps

module camus_lcc_datamover_executor_tb;
    localparam integer W=8,H=6,N=W*H;
    localparam logic [31:0] MASK_BASE=32'h0000_0100;
    localparam logic [31:0] LABEL_BASE=32'h0000_1000;
    logic clk=0,rst=1,start=0;
    logic [8:0] width=W,height=H;
    logic [3:0] command_tag=4'h9;
    logic [31:0] watchdog_limit=0;
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
    logic [7:0] source[0:N-1],expected[0:N-1];
    integer i;

    logic enc_mm2s_cmd_ready,enc_mm2s_sts_valid,enc_mm2s_valid;
    logic [7:0] enc_mm2s_sts_data;
    logic [127:0] enc_mm2s_data;
    logic [15:0] enc_mm2s_keep;
    logic enc_mm2s_last,enc_s2mm_cmd_ready,enc_s2mm_sts_valid,enc_s2mm_ready;
    logic [7:0] enc_s2mm_sts_data;
    logic ddr_mm2s_sts_valid,ddr_s2mm_sts_valid;
    logic [7:0] ddr_mm2s_sts_data,ddr_s2mm_sts_data;
    logic delay_pass3_status,release_pass3_status;
    logic pending_mm2s_status,pending_s2mm_status;
    logic [7:0] held_mm2s_status,held_s2mm_status;

    always #5 clk=~clk;

    assign s_axis_mm2s_sts_tvalid=delay_pass3_status
        ?(release_pass3_status&&pending_mm2s_status):ddr_mm2s_sts_valid;
    assign s_axis_mm2s_sts_tdata=delay_pass3_status
        ?held_mm2s_status:ddr_mm2s_sts_data;
    assign s_axis_s2mm_sts_tvalid=delay_pass3_status
        ?(release_pass3_status&&pending_s2mm_status):ddr_s2mm_sts_valid;
    assign s_axis_s2mm_sts_tdata=delay_pass3_status
        ?held_s2mm_status:ddr_s2mm_sts_data;

    always_ff @(posedge clk) begin
        if(rst) begin
            pending_mm2s_status<=1'b0;
            pending_s2mm_status<=1'b0;
            held_mm2s_status<='0;
            held_s2mm_status<='0;
        end else if(delay_pass3_status) begin
            if(ddr_mm2s_sts_valid) begin
                pending_mm2s_status<=1'b1;
                held_mm2s_status<=ddr_mm2s_sts_data;
            end
            if(ddr_s2mm_sts_valid) begin
                pending_s2mm_status<=1'b1;
                held_s2mm_status<=ddr_s2mm_sts_data;
            end
            if(release_pass3_status&&s_axis_mm2s_sts_tready)
                pending_mm2s_status<=1'b0;
            if(release_pass3_status&&s_axis_s2mm_sts_tready)
                pending_s2mm_status<=1'b0;
        end
    end

    always @(posedge clk) begin
        if(!rst&&m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready)
            $display("MM CMD tag=%0d addr=%h bytes=%0d",m_axis_mm2s_cmd_tdata[67:64],
                m_axis_mm2s_cmd_tdata[63:32],m_axis_mm2s_cmd_tdata[22:0]);
        if(!rst&&m_axis_s2mm_cmd_tvalid&&m_axis_s2mm_cmd_tready)
            $display("S2 CMD tag=%0d addr=%h bytes=%0d",m_axis_s2mm_cmd_tdata[67:64],
                m_axis_s2mm_cmd_tdata[63:32],m_axis_s2mm_cmd_tdata[22:0]);
        if(!rst&&m_axis_s2mm_tvalid&&m_axis_s2mm_tready)
            $display("S2 DATA keep=%h last=%b state=%0d labels=%0d masks=%0d",
                m_axis_s2mm_tkeep,m_axis_s2mm_tlast,dut.state,
                dut.label_out_count,dut.mask_out_count);
        if(!rst&&s_axis_mm2s_tvalid&&s_axis_mm2s_tready)
            $display("MM DATA keep=%h last=%b state=%0d remaining=%0d",
                s_axis_mm2s_tkeep,s_axis_mm2s_tlast,dut.state,ddr.dr_remaining);
        if(!rst&&dut.raw_valid&&dut.raw_ready_core)
            $display("RAW pixel=%0d lane=%0d hold=%b ext_valid=%b ext_ready=%b",
                dut.raw_data,dut.u_raw_reader.lane,dut.u_raw_reader.hold_valid,
                s_axis_mm2s_tvalid,s_axis_mm2s_tready);
        if(!rst&&s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready)
            $display("MM STS %h state=%0d",s_axis_mm2s_sts_tdata,dut.state);
        if(!rst&&s_axis_s2mm_sts_tvalid&&s_axis_s2mm_sts_tready)
            $display("S2 STS %h state=%0d",s_axis_s2mm_sts_tdata,dut.state);
    end

    camus_lcc_datamover_executor #(.MAX_LABELS(64)) dut(
        .clk,.rst,.start,.mask_base_bytes(MASK_BASE),.label_base_bytes(LABEL_BASE),
        .width,.height,.command_tag,.watchdog_limit,.*);

    camus_dual_datamover_ddr_model #(.MEM_BYTES(65536)) ddr(
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
        .dec_mm2s_sts_valid(ddr_mm2s_sts_valid),
        .dec_mm2s_sts_ready(s_axis_mm2s_sts_tready),
        .dec_mm2s_sts_data(ddr_mm2s_sts_data),
        .dec_mm2s_valid(s_axis_mm2s_tvalid),.dec_mm2s_ready(s_axis_mm2s_tready),
        .dec_mm2s_data(s_axis_mm2s_tdata),.dec_mm2s_keep(s_axis_mm2s_tkeep),
        .dec_mm2s_last(s_axis_mm2s_tlast),
        .dec_s2mm_cmd_valid(m_axis_s2mm_cmd_tvalid),
        .dec_s2mm_cmd_ready(m_axis_s2mm_cmd_tready),
        .dec_s2mm_cmd_data(m_axis_s2mm_cmd_tdata),
        .dec_s2mm_sts_valid(ddr_s2mm_sts_valid),
        .dec_s2mm_sts_ready(s_axis_s2mm_sts_tready),
        .dec_s2mm_sts_data(ddr_s2mm_sts_data),
        .dec_s2mm_valid(m_axis_s2mm_tvalid),.dec_s2mm_ready(m_axis_s2mm_tready),
        .dec_s2mm_data(m_axis_s2mm_tdata),.dec_s2mm_keep(m_axis_s2mm_tkeep),
        .dec_s2mm_last(m_axis_s2mm_tlast),.error(ddr_error));

    // A real AXI DataMover may return command status after the final stream
    // beat and after the LCC core's one-cycle done pulse. Hold both pass-3
    // status channels until that pulse has passed to exercise the latch.
    initial begin
        delay_pass3_status=1'b0;
        release_pass3_status=1'b0;
        wait(!rst);
        wait(dut.state == 4'd8);
        delay_pass3_status=1'b1;
        wait(dut.u_core.done);
        repeat(16) @(posedge clk);
        release_pass3_status=1'b1;
    end

    initial begin
        for(i=0;i<N;i=i+1) begin source[i]=0;expected[i]=0;end
        for(i=0;i<3;i=i+1) begin
            source[(i+1)*W+1]=1;source[(i+1)*W+2]=1;source[(i+1)*W+3]=1;
            expected[(i+1)*W+1]=1;expected[(i+1)*W+2]=1;expected[(i+1)*W+3]=1;
        end
        source[7]=1;
        source[1*W+5]=2;source[2*W+6]=2;source[3*W+7]=2;
        expected[1*W+5]=2;expected[2*W+6]=2;expected[3*W+7]=2;
        source[5*W]=2;
        source[4*W+3]=3;source[4*W+4]=3;source[5*W+4]=3;
        expected[4*W+3]=3;expected[4*W+4]=3;expected[5*W+4]=3;
        source[0]=3;source[1]=3;
    end

    initial begin
        repeat(5) @(posedge clk);
        for(i=0;i<N;i=i+1) ddr.mem[MASK_BASE+i]=source[i];
        @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        fork : finish_or_timeout
            begin
                wait(done);@(negedge clk);
                if(error||overflow||ddr_error)
                    $fatal(1,"summary error=%b overflow=%b ddr=%b state=%0d core=%0d labels=%0d masks=%0d",
                        error,overflow,ddr_error,dut.state,dut.u_core.state,
                        dut.label_out_count,dut.mask_out_count);
                for(i=0;i<N;i=i+1)
                    if(ddr.mem[MASK_BASE+i]!==expected[i])
                        $fatal(1,"pixel=%0d got=%0d expected=%0d",i,ddr.mem[MASK_BASE+i],expected[i]);
                if (area_counts !== {17'd3,17'd3,17'd9})
                    $fatal(1,"final-mask areas differ from filtered DDR mask: %h",area_counts);
                $display("PASS camus_lcc_datamover pixels=%0d labels=%0d cycles=%0d",N,labels_used,cycle_count);
            end
            begin
                repeat(200000) @(posedge clk);
                $fatal(1,"timeout state=%0d core=%0d mm=%b s2=%b stream=%b labels=%0d masks=%0d ddr=%b",
                    dut.state,dut.u_core.state,dut.mm_status_seen,dut.s2_status_seen,
                    dut.stream_done_seen,dut.label_out_count,dut.mask_out_count,ddr_error);
            end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
