`timescale 1ns/1ps
// Minimal AXI4-Lite control/status slave for the CAMUS PL engine.
// One write and one read transaction may be outstanding; AW and W are
// accepted independently, as required by AXI-Lite.
module camus_axi_ctrl #(
    parameter integer ADDR_W = 8
) (
    input logic s_axi_aclk,
    input logic s_axi_aresetn,
    input logic [ADDR_W-1:0] s_axi_awaddr,
    input logic s_axi_awvalid,
    output logic s_axi_awready,
    input logic [31:0] s_axi_wdata,
    input logic [3:0] s_axi_wstrb,
    input logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    input logic [ADDR_W-1:0] s_axi_araddr,
    input logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input logic s_axi_rready,
    output logic start_pulse,
    output logic soft_reset_pulse,
    output logic abort_pulse,
    output logic [31:0] cfg_width,
    output logic [31:0] cfg_height,
    output logic [31:0] cfg_input_base,
    output logic [31:0] cfg_output_base,
    output logic [31:0] cfg_weight_base,
    output logic [31:0] cfg_weight_bytes,
    output logic [31:0] cfg_layer_index,
    input logic busy,
    input logic done,
    input logic error,
    input logic overflow,
    input logic weight_fault,
    input logic cache_fault,
    input logic [31:0] cycle_count
);
    logic aw_hold, w_hold;
    logic [ADDR_W-1:0] awaddr_hold;
    logic [31:0] wdata_hold;
    logic [3:0] wstrb_hold;
    integer b;

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_bresp = 2'b00; // OKAY
    assign s_axi_rresp = 2'b00; // OKAY

    function automatic [31:0] read_reg(input logic [ADDR_W-1:0] addr);
        begin
            case (addr[7:2])
                6'h01: read_reg = {26'd0, cache_fault, weight_fault, overflow, error, done, busy};
                6'h02: read_reg = {16'd0, cfg_height[15:0], cfg_width[15:0]};
                6'h03: read_reg = cfg_input_base;
                6'h04: read_reg = cfg_output_base;
                6'h05: read_reg = cfg_weight_base;
                6'h06: read_reg = cfg_weight_bytes;
                6'h07: read_reg = cycle_count;
                6'h08: read_reg = cfg_layer_index;
                default: read_reg = 32'd0;
            endcase
        end
    endfunction

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold <= 1'b0;
            w_hold <= 1'b0;
            awaddr_hold <= '0;
            wdata_hold <= '0;
            wstrb_hold <= '0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
            start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            abort_pulse <= 1'b0;
            cfg_width <= 32'd256;
            cfg_height <= 32'd256;
            cfg_input_base <= '0;
            cfg_output_base <= '0;
            cfg_weight_base <= '0;
            cfg_weight_bytes <= '0;
            cfg_layer_index <= '0;
        end else begin
            start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            abort_pulse <= 1'b0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (aw_hold && w_hold && !s_axi_bvalid) begin
                case (awaddr_hold[7:2])
                    6'h00: begin
                        start_pulse <= wdata_hold[0];
                        soft_reset_pulse <= wdata_hold[1];
                        abort_pulse <= wdata_hold[3];
                    end
                    6'h02: begin
                        if (wstrb_hold[0]) cfg_width[7:0] <= wdata_hold[7:0];
                        if (wstrb_hold[1]) cfg_width[15:8] <= wdata_hold[15:8];
                        if (wstrb_hold[2]) cfg_height[7:0] <= wdata_hold[23:16];
                        if (wstrb_hold[3]) cfg_height[15:8] <= wdata_hold[31:24];
                    end
                    6'h03: for (b = 0; b < 4; b = b + 1)
                        if (wstrb_hold[b]) cfg_input_base[b*8 +: 8] <= wdata_hold[b*8 +: 8];
                    6'h04: for (b = 0; b < 4; b = b + 1)
                        if (wstrb_hold[b]) cfg_output_base[b*8 +: 8] <= wdata_hold[b*8 +: 8];
                    6'h05: for (b = 0; b < 4; b = b + 1)
                        if (wstrb_hold[b]) cfg_weight_base[b*8 +: 8] <= wdata_hold[b*8 +: 8];
                    6'h06: for (b = 0; b < 4; b = b + 1)
                        if (wstrb_hold[b]) cfg_weight_bytes[b*8 +: 8] <= wdata_hold[b*8 +: 8];
                    6'h08: for (b = 0; b < 4; b = b + 1)
                        if (wstrb_hold[b]) cfg_layer_index[b*8 +: 8] <= wdata_hold[b*8 +: 8];
                    default: ;
                endcase
                aw_hold <= 1'b0;
                w_hold <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rdata <= read_reg(s_axi_araddr);
                s_axi_rvalid <= 1'b1;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end
endmodule
