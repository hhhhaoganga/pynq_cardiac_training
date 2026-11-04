`timescale 1ns/1ps
// One outstanding burst per direction; up to 64 beats, never crossing 4 KiB.
// Reads wait for completion of pending writes, preserving microprogram ordering.
module knot_dma (
    input wire clk,reset, input wire [31:0] base,
    input wire rd_cmd_valid, output wire rd_cmd_ready,
    input wire [31:0] rd_addr,input wire [15:0] rd_count,
    output wire rd_valid,input wire rd_ready,output wire [63:0] rd_data,
    input wire wr_cmd_valid,output wire wr_cmd_ready,
    input wire [31:0] wr_addr,input wire [15:0] wr_count,
    input wire wr_valid,output wire wr_ready,input wire [63:0] wr_data,
    output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
    input wire [63:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
    output wire [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
    output wire [63:0] wdata,output wire wlast,wvalid,input wire wready,
    input wire [1:0] bresp,input wire bvalid,output wire bready,
    output reg fault
);
    localparam IDLE=0,ADDR=1,DATA=2,RESP=3;
    reg [1:0] rs,ws;
    reg [31:0] rp,wp;
    reg [15:0] rl,wl;
    reg [6:0] rb,wb;
    function automatic [6:0] burst(input [31:0] addr,input [15:0] remaining);
        reg [9:0] page_left;reg [15:0] n;
        begin
            page_left=10'd512-{1'b0,addr[11:3]};
            n=remaining>64?16'd64:remaining;
            burst=n>page_left?page_left:n;
        end
    endfunction
    assign rd_cmd_ready=rs==IDLE&&ws==IDLE&&!fault;
    assign wr_cmd_ready=ws==IDLE&&rs==IDLE&&!fault;
    assign araddr=rp;assign arlen=burst(rp,rl)-1;assign arvalid=rs==ADDR&&!fault;
    assign awaddr=wp;assign awlen=burst(wp,wl)-1;assign awvalid=ws==ADDR&&!fault;
    assign rd_data=rdata;assign rd_valid=rs==DATA&&rvalid&&!fault;assign rready=rs==DATA&&rd_ready&&!fault;
    assign wdata=wr_data;assign wvalid=ws==DATA&&wr_valid&&!fault;assign wr_ready=ws==DATA&&wready&&!fault;
    assign wlast=wb==1;assign bready=ws==RESP&&!fault;
    always @(posedge clk) begin
        if(reset)begin rs<=IDLE;ws<=IDLE;fault<=0;rp<=0;wp<=0;rl<=0;wl<=0;rb<=0;wb<=0;end
        else begin
            if(rd_cmd_valid&&rd_cmd_ready)begin
                rp<=base+(rd_addr<<3);rl<=rd_count;rs<=ADDR;
                if(rd_count==0||base[2:0]!=0)fault<=1;
            end
            if(arvalid&&arready)begin rb<=burst(rp,rl);rs<=DATA;end
            if(rvalid&&rready)begin
                rp<=rp+8;rl<=rl-1;rb<=rb-1;
                if(rresp!=0||(rlast!=(rb==1)))fault<=1;
                if(rb==1)rs<=rl==1?IDLE:ADDR;
            end
            if(wr_cmd_valid&&wr_cmd_ready)begin
                wp<=base+(wr_addr<<3);wl<=wr_count;ws<=ADDR;
                if(wr_count==0||base[2:0]!=0)fault<=1;
            end
            if(awvalid&&awready)begin wb<=burst(wp,wl);ws<=DATA;end
            if(wvalid&&wready)begin
                wp<=wp+8;wl<=wl-1;wb<=wb-1;
                if(wb==1)ws<=RESP;
            end
            if(bvalid&&bready)begin
                if(bresp!=0)fault<=1;
                ws<=wl==0?IDLE:ADDR;
            end
        end
    end
endmodule
