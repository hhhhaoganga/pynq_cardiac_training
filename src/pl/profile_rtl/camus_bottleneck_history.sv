`timescale 1ns/1ps

module camus_history_bank #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input logic clk,
    input logic write_enable,
    input logic [ADDR_W-1:0] write_address,
    input logic [63:0] write_data,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_address,
    output logic [63:0] read_data
);
    (* ram_style = "block" *) logic [63:0] memory [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule

// Three-bank causal history for 32x32 bottlenecks. After a frame is committed,
// the temporal stream emits older, previous, current groups for each pixel.
// Frame 0 emits F0/F0/F0 and frame 1 emits F0/F0/F1.
module camus_bottleneck_history #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic clk,
    input  logic rst,
    input  logic clear_history,

    input  logic write_start,
    input  logic write_valid,
    output logic write_ready,
    input  logic [63:0] write_data,
    input  logic write_last,
    output logic write_done,

    input  logic temporal_start,
    input  logic [15:0] temporal_first_pixel,
    input  logic [15:0] pixels,
    input  logic [2:0] groups_per_frame,
    output logic temporal_valid,
    input  logic temporal_ready,
    output logic [63:0] temporal_data,
    output logic temporal_last,
    output logic temporal_done,

    output logic [1:0] history_count,
    output logic error
);
    logic [1:0] write_bank, older_bank, previous_bank;
    logic [1:0] read_older_bank, read_previous_bank, read_current_bank;
    logic write_busy;
    logic [ADDR_W:0] write_address;

    logic temporal_busy;
    logic [15:0] read_pixel;
    logic [15:0] first_pixel_reg;
    logic [2:0] read_group;
    logic [1:0] read_source;
    logic [ADDR_W-1:0] read_address;
    logic [1:0] selected_read_bank;
    logic read_pending;
    logic read_pending_last;
    logic [1:0] pending_bank;
    logic [63:0] bank_read_data [0:2];
    logic [2:0] bank_write_enable;
    logic [2:0] bank_read_enable;
    logic temporal_advance;

    assign write_ready = write_busy;
    assign temporal_advance = !temporal_valid || temporal_ready;
    assign selected_read_bank = read_source == 0 ? read_older_bank
        : read_source == 1 ? read_previous_bank : read_current_bank;
    assign read_address = (first_pixel_reg + read_pixel) * groups_per_frame + read_group;
    always_comb begin
        bank_write_enable = 3'b000;
        bank_read_enable = 3'b000;
        if (write_valid && write_ready)
            bank_write_enable[write_bank] = 1'b1;
        if (temporal_busy && temporal_advance && !read_pending)
            bank_read_enable[selected_read_bank] = 1'b1;
    end

    genvar bank;
    generate
        for (bank = 0; bank < 3; bank = bank + 1) begin : g_history_bank
            camus_history_bank #(.DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_bank (
                .clk(clk), .write_enable(bank_write_enable[bank]),
                .write_address(write_address[ADDR_W-1:0]),
                .write_data(write_data), .read_enable(bank_read_enable[bank]),
                .read_address(read_address), .read_data(bank_read_data[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            write_bank <= 0;
            older_bank <= 0;
            previous_bank <= 0;
            read_older_bank <= 0;
            read_previous_bank <= 0;
            read_current_bank <= 0;
            write_busy <= 1'b0;
            write_address <= '0;
            write_done <= 1'b0;
            temporal_busy <= 1'b0;
            read_pixel <= '0;
            first_pixel_reg <= '0;
            read_group <= '0;
            read_source <= '0;
            read_pending <= 1'b0;
            read_pending_last <= 1'b0;
            pending_bank <= '0;
            temporal_valid <= 1'b0;
            temporal_data <= '0;
            temporal_last <= 1'b0;
            temporal_done <= 1'b0;
            history_count <= 0;
            error <= 1'b0;
        end else begin
            write_done <= 1'b0;
            temporal_done <= 1'b0;

            if (clear_history) begin
                write_bank <= 0;
                older_bank <= 0;
                previous_bank <= 0;
                history_count <= 0;
                write_busy <= 1'b0;
                temporal_busy <= 1'b0;
                read_pending <= 1'b0;
                temporal_valid <= 1'b0;
                error <= 1'b0;
            end else begin
                if (write_start) begin
                    if (write_busy || temporal_busy) begin
                        error <= 1'b1;
                    end else begin
                        write_busy <= 1'b1;
                        write_address <= 0;
                    end
                end

                if (write_valid && write_ready) begin
                    if (write_last) begin
                        write_busy <= 1'b0;
                        write_done <= 1'b1;

                        read_current_bank <= write_bank;
                        if (history_count == 0) begin
                            read_older_bank <= write_bank;
                            read_previous_bank <= write_bank;
                            older_bank <= write_bank;
                            previous_bank <= write_bank;
                            write_bank <= write_bank == 2 ? 0 : write_bank + 1'b1;
                            history_count <= 1;
                        end else if (history_count == 1) begin
                            read_older_bank <= older_bank;
                            read_previous_bank <= previous_bank;
                            previous_bank <= write_bank;
                            write_bank <= 3 - older_bank - write_bank;
                            history_count <= 2;
                        end else begin
                            read_older_bank <= older_bank;
                            read_previous_bank <= previous_bank;
                            older_bank <= previous_bank;
                            previous_bank <= write_bank;
                            write_bank <= older_bank;
                        end
                    end else if (write_address == DEPTH-1) begin
                        error <= 1'b1;
                        write_busy <= 1'b0;
                    end else begin
                        write_address <= write_address + 1'b1;
                    end
                end

                if (write_valid && !write_ready)
                    error <= 1'b1;

                if (temporal_start) begin
                    if (temporal_busy || write_busy || history_count == 0
                            || pixels == 0 || groups_per_frame == 0
                            || (temporal_first_pixel + pixels) * groups_per_frame > DEPTH) begin
                        error <= 1'b1;
                    end else begin
                        temporal_busy <= 1'b1;
                        first_pixel_reg <= temporal_first_pixel;
                        read_pixel <= 0;
                        read_group <= 0;
                        read_source <= 0;
                        read_pending <= 1'b0;
                        temporal_valid <= 1'b0;
                    end
                end else if (temporal_busy && temporal_advance) begin
                    // A consumed beat must not remain visible while the next
                    // synchronous BRAM read is being issued.
                    temporal_valid <= 1'b0;
                    if (read_pending) begin
                        temporal_valid <= 1'b1;
                        temporal_data <= bank_read_data[pending_bank];
                        temporal_last <= read_pending_last;
                        read_pending <= 1'b0;
                    end else begin
                        read_pending <= 1'b1;
                        pending_bank <= selected_read_bank;
                        read_pending_last <= read_pixel == pixels - 1'b1
                            && read_group == groups_per_frame - 1'b1
                            && read_source == 2;

                        // Concatenated temporal channels are source-major:
                        // all older groups, then all previous groups, then
                        // all current groups for one pixel.
                        if (read_group != groups_per_frame - 1'b1) begin
                            read_group <= read_group + 1'b1;
                        end else begin
                            read_group <= 0;
                            if (read_source != 2) begin
                                read_source <= read_source + 1'b1;
                            end else begin
                                read_source <= 0;
                                if (read_pixel == pixels - 1'b1)
                                    read_pixel <= 0;
                                else
                                    read_pixel <= read_pixel + 1'b1;
                            end
                        end
                    end
                end

                if (temporal_valid && temporal_ready && temporal_last) begin
                    temporal_valid <= 1'b0;
                    temporal_busy <= 1'b0;
                    temporal_done <= 1'b1;
                end
            end
        end
    end
endmodule
