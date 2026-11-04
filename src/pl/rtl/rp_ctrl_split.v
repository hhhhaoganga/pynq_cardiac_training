`timescale 1ns / 1ps
// AXI4-Lite 1:2 splitter for RMs with two control slaves behind the frozen
// 8-bit S_AXI_CTRL boundary (the width rm_seg fixed for the static shell).
//   0x00-0x7F -> m00 (address [6:0], e.g. AXI DMA registers 0x00-0x58)
//   0x80-0xFF -> m01 (address [3:0], e.g. HLS ap_ctrl_hs block 0x00-0x0C)
// Master addresses are 32-bit, zero-extended, so IP integrator can map each
// downstream slave at offset 0 of its own master address space.
// One transaction in flight per direction; control traffic only.
module rp_ctrl_split (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:M00_AXI:M01_AXI, ASSOCIATED_RESET aresetn" *)
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [31:0] m00_axi_awaddr,
    output wire        m00_axi_awvalid,
    input  wire        m00_axi_awready,
    output wire [31:0] m00_axi_wdata,
    output wire [3:0]  m00_axi_wstrb,
    output wire        m00_axi_wvalid,
    input  wire        m00_axi_wready,
    input  wire [1:0]  m00_axi_bresp,
    input  wire        m00_axi_bvalid,
    output wire        m00_axi_bready,
    output wire [31:0] m00_axi_araddr,
    output wire        m00_axi_arvalid,
    input  wire        m00_axi_arready,
    input  wire [31:0] m00_axi_rdata,
    input  wire [1:0]  m00_axi_rresp,
    input  wire        m00_axi_rvalid,
    output wire        m00_axi_rready,

    output wire [31:0] m01_axi_awaddr,
    output wire        m01_axi_awvalid,
    input  wire        m01_axi_awready,
    output wire [31:0] m01_axi_wdata,
    output wire [3:0]  m01_axi_wstrb,
    output wire        m01_axi_wvalid,
    input  wire        m01_axi_wready,
    input  wire [1:0]  m01_axi_bresp,
    input  wire        m01_axi_bvalid,
    output wire        m01_axi_bready,
    output wire [31:0] m01_axi_araddr,
    output wire        m01_axi_arvalid,
    input  wire        m01_axi_arready,
    input  wire [31:0] m01_axi_rdata,
    input  wire [1:0]  m01_axi_rresp,
    input  wire        m01_axi_rvalid,
    output wire        m01_axi_rready
);
    localparam [1:0] IDLE = 2'd0, ISSUE = 2'd1, RESP = 2'd2;

    // ---- write: take AW+W together, issue both to the target, pass B back ----
    reg [1:0]  wst;
    reg        wsel, aw_done, w_done;
    reg [7:0]  waddr;
    reg [31:0] wdata;
    reg [3:0]  wstrb;

    assign s_axi_awready = (wst == IDLE) && s_axi_awvalid && s_axi_wvalid;
    assign s_axi_wready  = s_axi_awready;

    wire m_awready = wsel ? m01_axi_awready : m00_axi_awready;
    wire m_wready  = wsel ? m01_axi_wready  : m00_axi_wready;
    wire m_bvalid  = wsel ? m01_axi_bvalid  : m00_axi_bvalid;
    wire awv = (wst == ISSUE) && !aw_done;
    wire wv  = (wst == ISSUE) && !w_done;

    always @(posedge aclk) begin
        if (!aresetn) begin
            wst <= IDLE;
            aw_done <= 1'b0;
            w_done <= 1'b0;
        end else case (wst)
            IDLE: if (s_axi_awready) begin
                waddr <= s_axi_awaddr;
                wsel  <= s_axi_awaddr[7];
                wdata <= s_axi_wdata;
                wstrb <= s_axi_wstrb;
                aw_done <= 1'b0;
                w_done <= 1'b0;
                wst <= ISSUE;
            end
            ISSUE: begin
                if (awv && m_awready) aw_done <= 1'b1;
                if (wv && m_wready) w_done <= 1'b1;
                if ((aw_done || m_awready) && (w_done || m_wready)) wst <= RESP;
            end
            RESP: if (m_bvalid && s_axi_bready) wst <= IDLE;
            default: wst <= IDLE;
        endcase
    end

    assign m00_axi_awaddr  = {25'd0, waddr[6:0]};
    assign m01_axi_awaddr  = {28'd0, waddr[3:0]};
    assign m00_axi_awvalid = awv && !wsel;
    assign m01_axi_awvalid = awv && wsel;
    assign m00_axi_wdata   = wdata;
    assign m01_axi_wdata   = wdata;
    assign m00_axi_wstrb   = wstrb;
    assign m01_axi_wstrb   = wstrb;
    assign m00_axi_wvalid  = wv && !wsel;
    assign m01_axi_wvalid  = wv && wsel;
    assign m00_axi_bready  = (wst == RESP) && !wsel && s_axi_bready;
    assign m01_axi_bready  = (wst == RESP) && wsel && s_axi_bready;
    assign s_axi_bvalid    = (wst == RESP) && m_bvalid;
    assign s_axi_bresp     = wsel ? m01_axi_bresp : m00_axi_bresp;

    // ---- read: latch AR, issue to the target, pass R back ----
    reg [1:0] rst;
    reg       rsel;
    reg [7:0] raddr;

    assign s_axi_arready = (rst == IDLE);
    wire m_arready = rsel ? m01_axi_arready : m00_axi_arready;
    wire m_rvalid  = rsel ? m01_axi_rvalid  : m00_axi_rvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            rst <= IDLE;
        end else case (rst)
            IDLE: if (s_axi_arvalid) begin
                raddr <= s_axi_araddr;
                rsel  <= s_axi_araddr[7];
                rst <= ISSUE;
            end
            ISSUE: if (m_arready) rst <= RESP;
            RESP: if (m_rvalid && s_axi_rready) rst <= IDLE;
            default: rst <= IDLE;
        endcase
    end

    assign m00_axi_araddr  = {25'd0, raddr[6:0]};
    assign m01_axi_araddr  = {28'd0, raddr[3:0]};
    assign m00_axi_arvalid = (rst == ISSUE) && !rsel;
    assign m01_axi_arvalid = (rst == ISSUE) && rsel;
    assign m00_axi_rready  = (rst == RESP) && !rsel && s_axi_rready;
    assign m01_axi_rready  = (rst == RESP) && rsel && s_axi_rready;
    assign s_axi_rvalid    = (rst == RESP) && m_rvalid;
    assign s_axi_rdata     = rsel ? m01_axi_rdata : m00_axi_rdata;
    assign s_axi_rresp     = rsel ? m01_axi_rresp : m00_axi_rresp;
endmodule
