`timescale 1ns/1ps

module camus_stream_axi_ctrl_tb;
    logic clk=0,s_axi_aresetn=0;
    logic [7:0] awaddr=0,araddr=0;
    logic awvalid=0,awready,wvalid=0,wready,bvalid,bready=0;
    logic [31:0] wdata=0,rdata;
    logic [3:0] wstrb=4'hf;
    logic [1:0] bresp,rresp;
    logic arvalid=0,arready,rvalid,rready=0;
    logic submit_pulse,soft_reset_pulse,clear_history_pulse;
    logic [31:0] cfg_input_base,cfg_mask_base,cfg_frame_id;
    logic [31:0] cfg_slot0_padded_base,cfg_slot0_skip_base,cfg_slot0_scratch_base;
    logic [31:0] cfg_slot1_padded_base,cfg_slot1_skip_base,cfg_slot1_scratch_base;
    logic [31:0] cfg_watchdog_limit;
    logic frame_ready=1,core_busy=0,core_error=0,dma_error=0;
    logic result_valid=0;
    logic [31:0] result_mask_base=0,result_frame_id=0;
    logic [63:0] frames_accepted=0,frames_completed=0;
    logic [63:0] pack_cycle_count=0,enc_cycle_count=0,dec_cycle_count=0;
    logic [4:0] enc_current_op=0,dec_current_op=0;
    logic [1:0] history_count=0;
    logic irq;
    logic [50:0] area_counts = {17'd65536,17'd123,17'd456};
    logic submit_seen=0;

    always #5 clk=~clk;
    always @(posedge clk) if(submit_pulse) submit_seen<=1;

    logic [31:0] cfg_post_base;
    logic result_ready;
    logic [63:0] post_cycle_count = 0;
    logic profile_rearm;
    logic [7:0] profile_read_index;
    logic [31:0] profile_read_data = 0;
    camus_stream_axi_ctrl dut(
        .s_axi_aclk(clk),.s_axi_aresetn(s_axi_aresetn),.s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid),.s_axi_awready(awready),.s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),
        .s_axi_rready(rready),.*);

    task automatic axi_write(input [7:0] address,input [31:0] value);
        begin
            @(negedge clk);awaddr=address;wdata=value;awvalid=1;wvalid=1;
            while(!(awready&&wready)) @(posedge clk);
            @(negedge clk);awvalid=0;wvalid=0;bready=1;
            while(!bvalid) @(posedge clk);
            @(negedge clk);bready=0;
        end
    endtask

    task automatic axi_read(input [7:0] address,output [31:0] value);
        begin
            @(negedge clk);araddr=address;arvalid=1;
            while(!arready) @(posedge clk);
            @(negedge clk);arvalid=0;rready=1;
            while(!rvalid) @(posedge clk);
            value=rdata;
            @(negedge clk);rready=0;
        end
    endtask

    logic [31:0] rd;
    initial begin
        repeat(4) @(posedge clk);@(negedge clk);s_axi_aresetn=1;
        axi_write(7'h08,32'h0100_0000);
        axi_write(7'h0c,32'h0200_0000);
        axi_write(7'h10,32'd17);
        axi_write(7'h64,32'd1);
        axi_write(7'h00,32'd1);
        @(posedge clk); #1;
        if(!submit_seen||cfg_input_base!=32'h0100_0000
                ||cfg_mask_base!=32'h0200_0000||cfg_frame_id!=17)
            $fatal(1,"configuration or submit mismatch");

        result_mask_base=32'h0200_0000;result_frame_id=17;result_valid=1;
        @(posedge clk);@(negedge clk);result_valid=0;
        axi_read(7'h04,rd);
        if(!rd[1]||!irq) $fatal(1,"done/irq did not latch status=%h",rd);
        axi_read(7'h58,rd);
        if(rd!=32'h0200_0000) $fatal(1,"result mask mismatch %h",rd);
        area_counts=0;
        axi_read(7'h70,rd);
        if(rd!=456) $fatal(1,"LV snapshot mismatch %h",rd);
        axi_read(7'h74,rd);
        if(rd!=123) $fatal(1,"MYO snapshot mismatch %h",rd);
        axi_read(7'h78,rd);
        if(rd!=65536) $fatal(1,"LA snapshot overflow %h",rd);
        axi_read(7'h7c,rd);
        if(rd!=32'h41524531) $fatal(1,"area capability mismatch");
        axi_write(7'h00,32'h8);
        if(irq) $fatal(1,"done acknowledge did not clear irq");

        frame_ready=0;
        axi_write(7'h00,32'd1);
        axi_read(7'h04,rd);
        if(!rd[3]) $fatal(1,"overflow did not latch status=%h",rd);
        axi_write(7'h00,32'h10);
        if(irq) $fatal(1,"fault acknowledge did not clear irq");
        $display("PASS camus_stream_axi_ctrl status=%h",rd);
        $finish;
    end
endmodule
