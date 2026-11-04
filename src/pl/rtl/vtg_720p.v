`timescale 1ns / 1ps
// Fixed 1280x720p60 video timing generator (CEA-861, 74.25 MHz pixel clock).
// Replaces the Xilinx v_tc core in the static shell: the demo only ever
// drives one mode, and v_tc cost ~950 LUTs / ~2,600 FFs that the RP needs.
// Output matches the v_tc 720p generator preset driven into v_axi4s_vid_out:
//   H: active 1280, front porch 110, sync 40, back porch 220 (total 1650)
//   V: active 720,  front porch 5,   sync 5,  back porch 20  (total 750)
//   HSYNC/VSYNC active high; VSYNC edges aligned to the HSYNC start pixel.
// gen_clken (from v_axi4s_vid_out vtg_ce) holds the counters until the
// output FIFO has locked, exactly like v_tc's gen_clken.
module vtg_720p (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF vtiming_out" *)
    input  wire clk,
    input  wire gen_clken,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out ACTIVE_VIDEO" *)
    output reg  active_video = 1'b0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out HBLANK" *)
    output reg  hblank = 1'b1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out VBLANK" *)
    output reg  vblank = 1'b1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out HSYNC" *)
    output reg  hsync = 1'b0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out VSYNC" *)
    output reg  vsync = 1'b0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 vtiming_out FIELD" *)
    output wire field_id
);
    localparam [10:0] H_ACTIVE = 1280, H_SYNC_START = 1390, H_SYNC_END = 1430, H_TOTAL = 1650;
    localparam [9:0]  V_ACTIVE = 720,  V_SYNC_START = 725,  V_SYNC_END = 730,  V_TOTAL = 750;

    reg [10:0] h = 0;
    reg [9:0]  v = 0;

    assign field_id = 1'b0;   // progressive

    always @(posedge clk) begin
        if (gen_clken) begin
            // Registered outputs for the current (h, v), then advance.
            hblank       <= h >= H_ACTIVE;
            vblank       <= v >= V_ACTIVE;
            active_video <= h < H_ACTIVE && v < V_ACTIVE;
            hsync        <= h >= H_SYNC_START && h < H_SYNC_END;
            if (h == H_SYNC_START)
                vsync <= v >= V_SYNC_START && v < V_SYNC_END;
            if (h == H_TOTAL - 1) begin
                h <= 0;
                v <= v == V_TOTAL - 1 ? 10'd0 : v + 1'b1;
            end else begin
                h <= h + 1'b1;
            end
        end
    end
endmodule
