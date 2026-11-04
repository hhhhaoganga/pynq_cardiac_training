`timescale 1ns/1ps

// One-entry AXIS command buffer. Command data crosses the timing boundary
// before the executor observes the downstream DataMover handshake.
module camus_axis72_command_register (
    input logic clk,
    input logic rst,
    input logic s_valid,
    output logic s_ready,
    input logic [71:0] s_data,
    output logic m_valid,
    input logic m_ready,
    output logic [71:0] m_data
);
    (* DONT_TOUCH = "TRUE" *) logic valid_reg;
    (* DONT_TOUCH = "TRUE" *) logic [71:0] data_reg;

    // Standard one-entry elastic-buffer handshake: the producer may fill an
    // empty register, while the registered output waits for the DataMover.
    assign s_ready = !valid_reg || m_ready;
    assign m_valid = valid_reg;
    assign m_data = data_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_reg <= 1'b0;
            data_reg <= '0;
        end else if (s_ready) begin
            valid_reg <= s_valid;
            if (s_valid)
                data_reg <= s_data;
        end
    end
endmodule
