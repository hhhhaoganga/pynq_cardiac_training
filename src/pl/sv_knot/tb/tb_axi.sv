`timescale 1ns/1ps
module tb_axi;
    reg  ctrl_clk;
    reg  ctrl_resetn;
    reg  fast_clk;
    reg  fast_resetn;
    wire  irq;
    reg [7:0] S_AXI_CTRL_awaddr;
    reg  S_AXI_CTRL_awvalid;
    wire  S_AXI_CTRL_awready;
    reg [31:0] S_AXI_CTRL_wdata;
    reg [3:0] S_AXI_CTRL_wstrb;
    reg  S_AXI_CTRL_wvalid;
    wire  S_AXI_CTRL_wready;
    wire [1:0] S_AXI_CTRL_bresp;
    wire  S_AXI_CTRL_bvalid;
    reg  S_AXI_CTRL_bready;
    reg [7:0] S_AXI_CTRL_araddr;
    reg  S_AXI_CTRL_arvalid;
    wire  S_AXI_CTRL_arready;
    wire [31:0] S_AXI_CTRL_rdata;
    wire [1:0] S_AXI_CTRL_rresp;
    wire  S_AXI_CTRL_rvalid;
    reg  S_AXI_CTRL_rready;
    wire [5:0] M_AXI_MEM_awid;
    wire [31:0] M_AXI_MEM_awaddr;
    wire [7:0] M_AXI_MEM_awlen;
    wire [2:0] M_AXI_MEM_awsize;
    wire [1:0] M_AXI_MEM_awburst;
    wire [3:0] M_AXI_MEM_awcache;
    wire [2:0] M_AXI_MEM_awprot;
    wire [3:0] M_AXI_MEM_awqos;
    wire  M_AXI_MEM_awvalid;
    reg  M_AXI_MEM_awready;
    wire [63:0] M_AXI_MEM_wdata;
    wire [7:0] M_AXI_MEM_wstrb;
    wire  M_AXI_MEM_wlast;
    wire  M_AXI_MEM_wvalid;
    reg  M_AXI_MEM_wready;
    reg [5:0] M_AXI_MEM_bid;
    reg [1:0] M_AXI_MEM_bresp;
    reg  M_AXI_MEM_bvalid;
    wire  M_AXI_MEM_bready;
    wire [5:0] M_AXI_MEM_arid;
    wire [31:0] M_AXI_MEM_araddr;
    wire [7:0] M_AXI_MEM_arlen;
    wire [2:0] M_AXI_MEM_arsize;
    wire [1:0] M_AXI_MEM_arburst;
    wire [3:0] M_AXI_MEM_arcache;
    wire [2:0] M_AXI_MEM_arprot;
    wire [3:0] M_AXI_MEM_arqos;
    wire  M_AXI_MEM_arvalid;
    reg  M_AXI_MEM_arready;
    reg [5:0] M_AXI_MEM_rid;
    reg [63:0] M_AXI_MEM_rdata;
    reg [1:0] M_AXI_MEM_rresp;
    reg  M_AXI_MEM_rlast;
    reg  M_AXI_MEM_rvalid;
    wire  M_AXI_MEM_rready;
    rm_cnn_top dut(.*);
    initial ctrl_clk=0;always #5 ctrl_clk=~ctrl_clk;
    always @* begin fast_clk=ctrl_clk;fast_resetn=ctrl_resetn;end
    reg [63:0] mem[0:399999],golden[0:208799];
    reg [31:0] random_state=32'h61987324;
    integer rleft=0,wleft=0,rptr=0,wptr=0,checked=0,errors=0;
    integer ar_bursts=0,aw_bursts=0,program_address,stall=1,wall_cycles=0;
    reg read_pending=0,bpending=0;
    reg [31:0] value;
    always @* begin
        M_AXI_MEM_arready=rleft==0&&(!stall||random_state[2:0]!=0);
        M_AXI_MEM_rvalid=rleft!=0&&read_pending;
        M_AXI_MEM_rdata=mem[rptr];M_AXI_MEM_rlast=rleft==1;M_AXI_MEM_rid=0;M_AXI_MEM_rresp=0;
        M_AXI_MEM_awready=wleft==0&&!bpending&&!M_AXI_MEM_bvalid&&(!stall||random_state[5:3]!=0);
        M_AXI_MEM_wready=wleft!=0&&(!stall||random_state[8:6]!=0);
        M_AXI_MEM_bresp=0;M_AXI_MEM_bid=0;
    end
    always @(posedge ctrl_clk)begin
        random_state<={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        if(ctrl_resetn)wall_cycles<=wall_cycles+1;
        if(M_AXI_MEM_arvalid&&M_AXI_MEM_arready)begin
            if(M_AXI_MEM_araddr[2:0]!=0||M_AXI_MEM_arsize!=3||M_AXI_MEM_arburst!=1||
                M_AXI_MEM_araddr[11:0]+(M_AXI_MEM_arlen+1)*8>4096)$fatal(1,"Invalid AR burst");
            rptr<=M_AXI_MEM_araddr/8;rleft<=M_AXI_MEM_arlen+1;read_pending<=0;ar_bursts<=ar_bursts+1;
        end else if(M_AXI_MEM_rvalid&&M_AXI_MEM_rready)begin
            rptr<=rptr+1;rleft<=rleft-1;read_pending<=!stall||random_state[11:9]!=0;
        end else if(rleft!=0&&!read_pending&&(!stall||random_state[11:9]!=0))read_pending<=1;
        if(M_AXI_MEM_awvalid&&M_AXI_MEM_awready)begin
            if(M_AXI_MEM_awaddr[2:0]!=0||M_AXI_MEM_awsize!=3||M_AXI_MEM_awburst!=1||
                M_AXI_MEM_awaddr[11:0]+(M_AXI_MEM_awlen+1)*8>4096)$fatal(1,"Invalid AW burst");
            wptr<=M_AXI_MEM_awaddr/8;wleft<=M_AXI_MEM_awlen+1;aw_bursts<=aw_bursts+1;
        end
        if(M_AXI_MEM_wvalid&&M_AXI_MEM_wready)begin
            if(M_AXI_MEM_wlast!=(wleft==1)||M_AXI_MEM_wstrb!=8'hff)$fatal(1,"Invalid W beat");
            mem[wptr]<=M_AXI_MEM_wdata;wptr<=wptr+1;wleft<=wleft-1;
            if(wleft==1)bpending<=1;
        end
        if(bpending&&(!stall||random_state[14:12]!=0))begin bpending<=0;M_AXI_MEM_bvalid<=1;end
        if(M_AXI_MEM_bvalid&&M_AXI_MEM_bready)M_AXI_MEM_bvalid<=0;
        if(dut.u_core.check_valid)begin
            errors=0;
            for(integer j=0;j<dut.u_core.check_count;j=j+1)
                if(mem[dut.u_core.check_address+j]!==golden[dut.u_core.check_address+j])begin
                    if(errors<4)$display("AXI_MISMATCH block=%0d beat=%0d actual=%016x golden=%016x",dut.u_core.check_block,j,mem[dut.u_core.check_address+j],golden[dut.u_core.check_address+j]);
                    errors=errors+1;
                end
            if(errors)$fatal(1,"AXI block mismatch");
            checked=checked+1;$display("AXI_BLOCK_PASS %0d cycles=%0d",dut.u_core.check_block,dut.cycles);
        end
        if(dut.core_fault||dut.dma_fault)$fatal(1,"Core/DMA fault");
        if(wall_cycles>20000000)$fatal(1,"Timeout");
    end
    task automatic send_aw(input [7:0] address);
        @(negedge ctrl_clk);S_AXI_CTRL_awaddr=address;S_AXI_CTRL_awvalid=1;
        do @(posedge ctrl_clk);while(!S_AXI_CTRL_awready);
        @(negedge ctrl_clk);S_AXI_CTRL_awvalid=0;
    endtask
    task automatic send_w(input [31:0] data);
        @(negedge ctrl_clk);S_AXI_CTRL_wdata=data;S_AXI_CTRL_wstrb=15;S_AXI_CTRL_wvalid=1;
        do @(posedge ctrl_clk);while(!S_AXI_CTRL_wready);
        @(negedge ctrl_clk);S_AXI_CTRL_wvalid=0;
    endtask
    task automatic csr_write(input [7:0] address,input [31:0] data,input bit data_first);
        if(data_first)begin send_w(data);repeat(3)@(negedge ctrl_clk);send_aw(address);end
        else begin send_aw(address);repeat(3)@(negedge ctrl_clk);send_w(data);end
        repeat(3)@(negedge ctrl_clk);S_AXI_CTRL_bready=1;
        do @(posedge ctrl_clk);while(!S_AXI_CTRL_bvalid);
        if(S_AXI_CTRL_bresp!=0)$fatal(1,"CSR write rejected");
        @(negedge ctrl_clk);S_AXI_CTRL_bready=0;
    endtask
    task automatic csr_read(input [7:0] address,output [31:0] data);
        @(negedge ctrl_clk);S_AXI_CTRL_araddr=address;S_AXI_CTRL_arvalid=1;
        do @(posedge ctrl_clk);while(!S_AXI_CTRL_arready);
        @(negedge ctrl_clk);S_AXI_CTRL_arvalid=0;
        repeat(3)@(negedge ctrl_clk);S_AXI_CTRL_rready=1;
        do @(posedge ctrl_clk);while(!S_AXI_CTRL_rvalid);
        data=S_AXI_CTRL_rdata;
        @(negedge ctrl_clk);S_AXI_CTRL_rready=0;
    endtask
    initial begin
        ctrl_resetn=0;M_AXI_MEM_bvalid=0;
        S_AXI_CTRL_awvalid=0;S_AXI_CTRL_wvalid=0;S_AXI_CTRL_bready=0;S_AXI_CTRL_arvalid=0;S_AXI_CTRL_rready=0;
        S_AXI_CTRL_awaddr=0;S_AXI_CTRL_wdata=0;S_AXI_CTRL_wstrb=0;S_AXI_CTRL_araddr=0;
        if(!$value$plusargs("PROGRAM=%d",program_address))$fatal(1,"PROGRAM required");
        if($value$plusargs("STALL=%d",stall))begin end
        $readmemh("fixture/memory.hex",mem);$readmemh("fixture/golden.hex",golden);
        repeat(10)@(negedge ctrl_clk);ctrl_resetn=1;
        csr_read(8'h3c,value);if(value!=32'h53564b31)$fatal(1,"ABI mismatch");
        csr_write(8'h10,0,0);csr_write(8'h18,program_address,1);csr_write(8'h04,1,0);csr_write(8'h00,1,1);
        wait(irq);csr_read(8'h00,value);
        if(!value[1]||value[4]||checked!=22)$fatal(1,"Bad completion status");
        csr_write(8'h0c,1,0);if(irq)$fatal(1,"IRQ clear failed");
        $display("SV_KNOT_AXI_PASS blocks=%0d cycles=%0d read_bursts=%0d write_bursts=%0d stall=%0d",checked,dut.cycles,ar_bursts,aw_bursts,stall);
        $finish;
    end
endmodule
