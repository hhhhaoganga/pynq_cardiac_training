`timescale 1ns/1ps
module camus_axi_ctrl_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rstn = 0;
    logic [7:0] awaddr, araddr;
    logic awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic awready, wready, bvalid, arready, rvalid;
    logic [31:0] wdata, rdata;
    logic [3:0] wstrb;
    logic [1:0] bresp, rresp;
    logic start_pulse, soft_reset_pulse, abort_pulse;
    logic [31:0] cfg_width, cfg_height, cfg_input_base, cfg_output_base;
    logic [31:0] cfg_weight_base, cfg_weight_bytes, cfg_layer_index;
    logic busy = 0, done = 0, error = 0, overflow = 0, weight_fault = 0, cache_fault = 0;
    logic [31:0] cycle_count = 0;
    logic start_seen = 0;
    always @(posedge clk) if (start_pulse) start_seen <= 1'b1;
    camus_axi_ctrl dut(.*,
        .s_axi_aclk(clk), .s_axi_aresetn(rstn), .s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready));

    task automatic axi_write(input [7:0] addr, input [31:0] data);
        begin
            @(negedge clk); awaddr <= addr; wdata <= data; wstrb <= 4'hf;
            awvalid <= 1; wvalid <= 1;
            while (!(awready && wready)) @(posedge clk);
            @(negedge clk); awvalid <= 0; wvalid <= 0; bready <= 1;
            while (!bvalid) @(posedge clk);
            @(negedge clk); bready <= 0;
        end
    endtask
    task automatic axi_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk); araddr <= addr; arvalid <= 1;
            while (!arready) @(posedge clk);
            @(negedge clk); arvalid <= 0; rready <= 1;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(negedge clk); rready <= 0;
        end
    endtask
    logic [31:0] rd;
    initial begin
        repeat (3) @(posedge clk);
        rstn <= 1;
        axi_write(8'h20, 32'd7);
        axi_write(8'h0c, 32'h12345678);
        axi_write(8'h00, 32'h1);
        #1;
        $display("axi cfg start_seen=%b layer=%0d input=%h", start_seen, cfg_layer_index, cfg_input_base);
        if (!start_seen || cfg_layer_index != 7 || cfg_input_base != 32'h12345678)
            $fatal(1, "AXI write/config mismatch");
        cycle_count <= 32'd99; busy <= 1; done <= 1;
        axi_read(8'h04, rd);
        if (rd != 32'h00000003) $fatal(1, "AXI status mismatch got=%h", rd);
        $display("CAMUS AXI control PASS status=%h", rd);
        $finish;
    end
endmodule
