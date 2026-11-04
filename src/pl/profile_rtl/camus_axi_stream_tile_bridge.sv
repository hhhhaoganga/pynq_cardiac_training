`timescale 1ns/1ps
// AXI4-Stream <-> BRAM tile bridge.  This is the data-plane endpoint that can
// sit between AXI DMA MM2S/S2MM streams and the shared CAMUS layer engine.
// The bridge keeps one registered read beat so downstream backpressure never
// loses a cache word.
module camus_axi_stream_tile_bridge #(
    parameter integer DATA_W = 128,
    parameter integer DEPTH = 1024,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input logic clk,
    input logic rst,
    input logic load_start,
    input logic [ADDR_W:0] load_beats,
    input logic [ADDR_W:0] read_beats,
    input logic read_start,
    input logic read_bank,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic signed [DATA_W-1:0] s_axis_tdata,
    input logic [DATA_W/8-1:0] s_axis_tkeep,
    input logic s_axis_tlast,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic signed [DATA_W-1:0] m_axis_tdata,
    output logic [DATA_W/8-1:0] m_axis_tkeep,
    output logic m_axis_tlast,
    output logic load_done,
    output logic read_done,
    output logic busy,
    output logic error,
    output logic [1:0] bank_ready
);
    logic wr_start_i, wr_valid_i, wr_ready_i, wr_last_i, wr_done_i, wr_busy_i, wr_bank_i;
    logic rd_en_i, rd_valid_i, active_bank_i;
    logic signed [DATA_W-1:0] rd_data_i;
    logic [ADDR_W-1:0] rd_addr_i;
    logic overflow_i;
    logic read_active;
    logic [ADDR_W:0] load_count, read_count;
    logic [ADDR_W:0] rd_issue_count;
    logic read_pending;
    logic out_valid_reg;
    logic signed [DATA_W-1:0] out_data_reg;
    logic out_last_reg;

    assign wr_start_i = load_start && !wr_busy_i;
    assign s_axis_tready = wr_busy_i && (load_count < load_beats);
    assign wr_valid_i = s_axis_tvalid && s_axis_tready;
    assign wr_last_i = s_axis_tlast || (load_count == load_beats-1);
    assign m_axis_tvalid = out_valid_reg;
    assign m_axis_tdata = out_data_reg;
    assign m_axis_tkeep = {DATA_W/8{1'b1}};
    assign m_axis_tlast = out_last_reg;
    assign busy = wr_busy_i || read_active || read_pending || out_valid_reg;
    assign error = overflow_i;

    camus_tile_pingpong #(.DATA_W(DATA_W), .DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_cache (
        .clk, .rst, .wr_start(wr_start_i), .wr_valid(wr_valid_i), .wr_ready(wr_ready_i),
        .wr_data(s_axis_tdata), .wr_last(wr_last_i), .wr_done(wr_done_i),
        .bank_ready, .wr_busy(wr_busy_i), .wr_bank(wr_bank_i), .rd_en(rd_en_i),
        .rd_bank(read_bank), .rd_addr(rd_addr_i), .rd_data(rd_data_i),
        .rd_valid(rd_valid_i), .swap_bank(1'b0), .active_bank(active_bank_i),
        .overflow(overflow_i));

    always_ff @(posedge clk) begin
        if (rst) begin
            load_count <= '0;
            read_count <= '0;
            rd_issue_count <= '0;
            read_active <= 1'b0;
            read_pending <= 1'b0;
            out_valid_reg <= 1'b0;
            out_data_reg <= '0;
            out_last_reg <= 1'b0;
            load_done <= 1'b0;
            read_done <= 1'b0;
            rd_addr_i <= '0;
            rd_en_i <= 1'b0;
        end else begin
            load_done <= 1'b0;
            read_done <= 1'b0;
            rd_en_i <= 1'b0;

            if (load_start && !wr_busy_i)
                load_count <= '0;
            if (wr_valid_i) begin
                load_count <= load_count + 1'b1;
                if (wr_last_i)
                    load_done <= 1'b1;
            end

            if (read_start && !read_active && !read_pending && !out_valid_reg) begin
                read_active <= 1'b1;
                read_count <= '0;
                rd_issue_count <= '0;
                rd_addr_i <= '0;
            end

            if (read_active && !read_pending && !out_valid_reg && (rd_issue_count < read_beats)) begin
                rd_en_i <= 1'b1;
                rd_addr_i <= rd_issue_count[ADDR_W-1:0];
                rd_issue_count <= rd_issue_count + 1'b1;
                read_pending <= 1'b1;
            end

            if (rd_valid_i && read_pending) begin
                out_data_reg <= rd_data_i;
                out_last_reg <= (read_count == read_beats-1);
                out_valid_reg <= 1'b1;
                read_pending <= 1'b0;
            end

            if (out_valid_reg && m_axis_tready) begin
                out_valid_reg <= 1'b0;
                if (out_last_reg) begin
                    read_active <= 1'b0;
                    read_done <= 1'b1;
                    read_count <= '0;
                end else begin
                    read_count <= read_count + 1'b1;
                end
                out_last_reg <= 1'b0;
            end
        end
    end
endmodule
