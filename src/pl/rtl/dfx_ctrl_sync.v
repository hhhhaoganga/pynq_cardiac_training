`timescale 1ns / 1ps
// Static-side DFX control glue. Fans the GPIO control word out to the RP
// clock domains and returns the shutdown-manager status to the GPIO input.
//   gpio_ctrl[0]   request shutdown (isolate RP AXI interfaces)
//   gpio_ctrl[1]   hold the RP in reset
//   gpio_status[0] control-path shutdown manager is in shutdown
//   gpio_status[1] memory-path shutdown manager is in shutdown
// Both shutdown managers and the RP bus interfaces run on ctrl_clk (the GPIO
// clock), so only the reserved fast_clk domain needs a synchronizer.
// The *_hold outputs feed proc_sys_reset aux_reset_in (active high).
module dfx_ctrl_sync (
    input  wire       ctrl_clk,
    input  wire       fast_clk,
    input  wire [1:0] gpio_ctrl,
    input  wire       ctrl_in_shutdown,
    input  wire       mem_in_shutdown,
    output wire       shutdown_req,
    output wire       ctrl_rp_hold,
    output wire       fast_rp_hold,
    output wire [1:0] gpio_status
);
    assign shutdown_req   = gpio_ctrl[0];
    assign ctrl_rp_hold   = gpio_ctrl[1];
    assign gpio_status    = {mem_in_shutdown, ctrl_in_shutdown};

    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) u_fast_hold (
        .src_clk(1'b0), .src_in(gpio_ctrl[1]),
        .dest_clk(fast_clk), .dest_out(fast_rp_hold));
endmodule
