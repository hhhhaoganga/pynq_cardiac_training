`timescale 1ns/1ps
// Handwritten SV core behind the unchanged static RP port contract.
module rm_cnn_top (
    input  wire        ctrl_clk,
    input  wire        ctrl_resetn,
    input  wire        fast_clk,
    input  wire        fast_resetn,
    output wire        irq,

    input  wire [7:0]  S_AXI_CTRL_awaddr,
    input  wire        S_AXI_CTRL_awvalid,
    output wire        S_AXI_CTRL_awready,
    input  wire [31:0] S_AXI_CTRL_wdata,
    input  wire [3:0]  S_AXI_CTRL_wstrb,
    input  wire        S_AXI_CTRL_wvalid,
    output wire        S_AXI_CTRL_wready,
    output wire [1:0]  S_AXI_CTRL_bresp,
    output wire        S_AXI_CTRL_bvalid,
    input  wire        S_AXI_CTRL_bready,
    input  wire [7:0]  S_AXI_CTRL_araddr,
    input  wire        S_AXI_CTRL_arvalid,
    output wire        S_AXI_CTRL_arready,
    output wire [31:0] S_AXI_CTRL_rdata,
    output wire [1:0]  S_AXI_CTRL_rresp,
    output wire        S_AXI_CTRL_rvalid,
    input  wire        S_AXI_CTRL_rready,

    output wire [5:0]  M_AXI_MEM_awid,
    output wire [31:0] M_AXI_MEM_awaddr,
    output wire [7:0]  M_AXI_MEM_awlen,
    output wire [2:0]  M_AXI_MEM_awsize,
    output wire [1:0]  M_AXI_MEM_awburst,
    output wire [3:0]  M_AXI_MEM_awcache,
    output wire [2:0]  M_AXI_MEM_awprot,
    output wire [3:0]  M_AXI_MEM_awqos,
    output wire        M_AXI_MEM_awvalid,
    input  wire        M_AXI_MEM_awready,
    output wire [63:0] M_AXI_MEM_wdata,
    output wire [7:0]  M_AXI_MEM_wstrb,
    output wire        M_AXI_MEM_wlast,
    output wire        M_AXI_MEM_wvalid,
    input  wire        M_AXI_MEM_wready,
    input  wire [5:0]  M_AXI_MEM_bid,
    input  wire [1:0]  M_AXI_MEM_bresp,
    input  wire        M_AXI_MEM_bvalid,
    output wire        M_AXI_MEM_bready,
    output wire [5:0]  M_AXI_MEM_arid,
    output wire [31:0] M_AXI_MEM_araddr,
    output wire [7:0]  M_AXI_MEM_arlen,
    output wire [2:0]  M_AXI_MEM_arsize,
    output wire [1:0]  M_AXI_MEM_arburst,
    output wire [3:0]  M_AXI_MEM_arcache,
    output wire [2:0]  M_AXI_MEM_arprot,
    output wire [3:0]  M_AXI_MEM_arqos,
    output wire        M_AXI_MEM_arvalid,
    input  wire        M_AXI_MEM_arready,
    input  wire [5:0]  M_AXI_MEM_rid,
    input  wire [63:0] M_AXI_MEM_rdata,
    input  wire [1:0]  M_AXI_MEM_rresp,
    input  wire        M_AXI_MEM_rlast,
    input  wire        M_AXI_MEM_rvalid,
    output wire        M_AXI_MEM_rready
);
    wire reset=!ctrl_resetn;
    reg start;
    reg [31:0] memory_base,program_beat;
    reg irq_enable,irq_pending,done_sticky;
    wire busy,done,core_fault,dma_fault;
    wire [63:0] cycles;
    wire rcv,rcr,rv,rr,wcv,wcr,wv,wr;
    wire [31:0] ra,wa;wire [15:0] rn,wn;wire [63:0] rd,wd;
    knot_core u_core(ctrl_clk,reset||dma_fault,start,program_beat,busy,done,core_fault,
        rcv,rcr,ra,rn,rv,rr,rd,wcv,wcr,wa,wn,wv,wr,wd,,,,,cycles);
    knot_dma u_dma(ctrl_clk,reset,memory_base,
        rcv,rcr,ra,rn,rv,rr,rd,wcv,wcr,wa,wn,wv,wr,wd,
        M_AXI_MEM_araddr,M_AXI_MEM_arlen,M_AXI_MEM_arvalid,M_AXI_MEM_arready,
        M_AXI_MEM_rdata,M_AXI_MEM_rresp,M_AXI_MEM_rlast,M_AXI_MEM_rvalid,M_AXI_MEM_rready,
        M_AXI_MEM_awaddr,M_AXI_MEM_awlen,M_AXI_MEM_awvalid,M_AXI_MEM_awready,
        M_AXI_MEM_wdata,M_AXI_MEM_wlast,M_AXI_MEM_wvalid,M_AXI_MEM_wready,
        M_AXI_MEM_bresp,M_AXI_MEM_bvalid,M_AXI_MEM_bready,dma_fault);
    assign M_AXI_MEM_arid=0;assign M_AXI_MEM_awid=0;
    assign M_AXI_MEM_arsize=3;assign M_AXI_MEM_awsize=3;
    assign M_AXI_MEM_arburst=1;assign M_AXI_MEM_awburst=1;
    assign M_AXI_MEM_arcache=3;assign M_AXI_MEM_awcache=3;
    assign M_AXI_MEM_arprot=0;assign M_AXI_MEM_awprot=0;
    assign M_AXI_MEM_arqos=0;assign M_AXI_MEM_awqos=0;
    assign M_AXI_MEM_wstrb=8'hff;
    assign irq=irq_enable&&(irq_pending||dma_fault||core_fault);
    // AW and W are captured independently; master need not assert them together.
    reg aw_hold,w_hold,bvalid,rvalid;
    reg [7:0] aw_address;
    reg [31:0] w_data,r_data;
    reg [3:0] w_strobe;
    reg [1:0] b_response;
    assign S_AXI_CTRL_awready=!aw_hold&&!bvalid;
    assign S_AXI_CTRL_wready=!w_hold&&!bvalid;
    assign S_AXI_CTRL_bvalid=bvalid;assign S_AXI_CTRL_bresp=b_response;
    assign S_AXI_CTRL_arready=!rvalid;
    assign S_AXI_CTRL_rvalid=rvalid;assign S_AXI_CTRL_rdata=r_data;assign S_AXI_CTRL_rresp=0;
    function automatic [31:0] merge_bytes(input [31:0] old_value,input [31:0] new_value,input [3:0] strobe);
        for(integer i=0;i<4;i=i+1)merge_bytes[i*8+:8]=strobe[i]?new_value[i*8+:8]:old_value[i*8+:8];
    endfunction
    always @(posedge ctrl_clk) begin
        if(reset)begin
            start<=0;memory_base<=0;program_beat<=0;irq_enable<=0;irq_pending<=0;done_sticky<=0;
            aw_hold<=0;w_hold<=0;bvalid<=0;rvalid<=0;b_response<=0;r_data<=0;
        end else begin
            start<=0;
            if(S_AXI_CTRL_awvalid&&S_AXI_CTRL_awready)begin aw_hold<=1;aw_address<=S_AXI_CTRL_awaddr;end
            if(S_AXI_CTRL_wvalid&&S_AXI_CTRL_wready)begin w_hold<=1;w_data<=S_AXI_CTRL_wdata;w_strobe<=S_AXI_CTRL_wstrb;end
            if(bvalid&&S_AXI_CTRL_bready)bvalid<=0;
            if(aw_hold&&w_hold&&!bvalid)begin
                aw_hold<=0;w_hold<=0;bvalid<=1;b_response<=0;
                case(aw_address)
                8'h00:if(w_strobe[0]&&w_data[0])begin
                    if(busy||dma_fault||memory_base[2:0]!=0)b_response<=2;
                    else begin start<=1;done_sticky<=0;irq_pending<=0;end
                end
                8'h04:if(w_strobe[0])irq_enable<=w_data[0];
                8'h0c:if(w_strobe[0]&&w_data[0])irq_pending<=0;
                8'h10:if(!busy)memory_base<=merge_bytes(memory_base,w_data,w_strobe);else b_response<=2;
                8'h18:if(!busy)program_beat<=merge_bytes(program_beat,w_data,w_strobe);else b_response<=2;
                default:b_response<=2;
                endcase
            end
            if(rvalid&&S_AXI_CTRL_rready)rvalid<=0;
            if(S_AXI_CTRL_arvalid&&S_AXI_CTRL_arready)begin
                rvalid<=1;
                case(S_AXI_CTRL_araddr)
                8'h00:r_data<={27'b0,(core_fault||dma_fault),!busy,!busy,done_sticky,1'b0};
                8'h04:r_data<={31'b0,irq_enable};
                8'h0c:r_data<={31'b0,irq_pending};
                8'h10:r_data<=memory_base;
                8'h18:r_data<=program_beat;
                8'h20:r_data<=cycles[31:0];
                8'h24:r_data<=cycles[63:32];
                8'h3c:r_data<=32'h53564b31; // SVK1, deliberately distinct ABI.
                default:r_data<=0;
                endcase
            end
            if(done)begin done_sticky<=1;irq_pending<=1;end
        end
    end
endmodule
