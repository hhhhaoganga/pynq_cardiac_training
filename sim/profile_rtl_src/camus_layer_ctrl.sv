`timescale 1ns/1ps
// Layer-level sequencing FSM.  It deliberately exposes phase enables rather
// than hiding fixed delays: DMA/cache and PE engines acknowledge each phase
// with a done pulse, so the same controller works for different tile sizes.
module camus_layer_ctrl (
    input logic clk,
    input logic rst,
    input logic start,
    input logic soft_reset,
    input logic abort,
    input logic load_done,
    input logic compute_done,
    input logic writeback_done,
    output logic load_active,
    output logic compute_active,
    output logic writeback_active,
    output logic busy,
    output logic done,
    output logic error,
    output logic [31:0] cycle_count,
    output logic [1:0] phase,
    input logic [31:0] cfg_width,
    input logic [31:0] cfg_height,
    input logic [31:0] cfg_in_channels,
    input logic [31:0] cfg_out_channels,
    output logic [31:0] active_width,
    output logic [31:0] active_height,
    output logic [31:0] active_in_channels,
    output logic [31:0] active_out_channels
);
    localparam logic [1:0] PH_IDLE = 2'd0;
    localparam logic [1:0] PH_LOAD = 2'd1;
    localparam logic [1:0] PH_COMPUTE = 2'd2;
    localparam logic [1:0] PH_WRITEBACK = 2'd3;
    logic [1:0] state;

    assign load_active = (state == PH_LOAD);
    assign compute_active = (state == PH_COMPUTE);
    assign writeback_active = (state == PH_WRITEBACK);
    assign busy = (state != PH_IDLE);
    assign phase = state;

    always_ff @(posedge clk) begin
        if (rst || soft_reset) begin
            state <= PH_IDLE;
            done <= 1'b0;
            error <= 1'b0;
            cycle_count <= '0;
            active_width <= '0;
            active_height <= '0;
            active_in_channels <= '0;
            active_out_channels <= '0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 1'b1;

            if (abort && busy) begin
                state <= PH_IDLE;
                error <= 1'b1;
            end else begin
                case (state)
                    PH_IDLE: begin
                        cycle_count <= '0;
                        if (start) begin
                            active_width <= cfg_width;
                            active_height <= cfg_height;
                            active_in_channels <= cfg_in_channels;
                            active_out_channels <= cfg_out_channels;
                            state <= PH_LOAD;
                        end
                    end
                    PH_LOAD: if (load_done) state <= PH_COMPUTE;
                    PH_COMPUTE: if (compute_done) state <= PH_WRITEBACK;
                    PH_WRITEBACK: if (writeback_done) begin
                        state <= PH_IDLE;
                        done <= 1'b1;
                    end
                    default: state <= PH_IDLE;
                endcase
            end
        end
    end
endmodule
