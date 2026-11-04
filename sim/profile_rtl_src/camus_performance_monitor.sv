`timescale 1ns/1ps

// Passive capture, frozen after SAMPLE_FRAMES. No feedback to compute or DMA.
// op*8 fields: cycles, load_wait, compute, output_wait, output_stall,
// token_fire, input_empty_when_ready, pending_token_output_blocked.
module camus_performance_monitor #(
    parameter integer WARMUP_FRAMES = 8,
    parameter integer SAMPLE_FRAMES = 64,
    parameter integer FIRST_OP = 11,
    parameter integer LAST_OP = 27
) (
    input logic clk, input logic rst, input logic rearm,
    input logic dec_start, input logic dec_done,
    input logic enc_busy, input logic dec_busy, input logic pack_busy,
    input logic history_reset, input logic core_error,
    input logic op_start, input logic op_done,
    input logic [4:0] op_index,
    input logic [127:0] conv_metrics,
    input logic [2:0] token_events,
    input logic [7:0] read_index,
    output logic [31:0] read_data
);
    (* ram_style = "block" *) logic [31:0] totals [0:255];
    logic [31:0] table_read, accumulator_read, sum_reg;
    logic clearing, serial_busy, ready, fault;
    logic [7:0] clear_address, update_address;
    logic [1:0] update_phase;
    logic [2:0] update_field;
    logic [255:0] update_values;
    logic pending_valid;
    logic [255:0] pending_values;
    logic [7:0] pending_address;
    logic [31:0] warmups, samples;
    logic frame_selected, capture_active, op_active;
    logic [4:0] active_op;
    logic [31:0] op_cycles, tokens, input_wait, capacity_wait;
    logic [31:0] wall_cycles, enc_cycles, dec_cycles, overlap_cycles;
    logic [31:0] pack_cycles, reset_count, interval_cycles;
    logic [31:0] first_completion_wall;
    logic last_done_seen;
    logic [32:0] sum_wide;
    logic [7:0] ram_address;
    logic ram_write;

    assign sum_wide = {1'b0, accumulator_read} + {1'b0, update_values[31:0]};
    assign ram_address = clearing ? clear_address : update_address;
    assign ram_write = clearing || (serial_busy && update_phase == 2);
    always_ff @(posedge clk) begin
        table_read <= totals[read_index];
        accumulator_read <= totals[ram_address];
        if (ram_write)
            totals[ram_address] <= clearing ? 32'd0 : sum_reg;
    end

    always_comb begin
        case (read_index)
            0: read_data = 32'h50524631; // PRF1
            1: read_data = {28'd0, fault, capture_active, clearing, ready};
            2: read_data = samples;
            3: read_data = SAMPLE_FRAMES;
            4: read_data = 32'd100000000;
            5: read_data = warmups;
            6: read_data = wall_cycles;
            7: read_data = enc_cycles;
            8: read_data = dec_cycles;
            9: read_data = overlap_cycles;
            10: read_data = pack_cycles;
            11: read_data = reset_count;
            12: read_data = interval_cycles;
            13: read_data = 32'd8;
            14: read_data = FIRST_OP;
            15: read_data = LAST_OP;
            default: read_data = table_read;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst || rearm) begin
            clearing <= 1;
            clear_address <= 0;
            serial_busy <= 0;
            ready <= 0;
            fault <= 0;
            update_phase <= 0;
            update_field <= 0;
            update_address <= 0;
            update_values <= 0;
            pending_valid <= 0;
            pending_values <= 0;
            pending_address <= 0;
            sum_reg <= 0;
            warmups <= 0;
            samples <= 0;
            frame_selected <= 0;
            capture_active <= 0;
            op_active <= 0;
            active_op <= 0;
            op_cycles <= 0;
            tokens <= 0;
            input_wait <= 0;
            capacity_wait <= 0;
            wall_cycles <= 0;
            enc_cycles <= 0;
            dec_cycles <= 0;
            overlap_cycles <= 0;
            pack_cycles <= 0;
            reset_count <= 0;
            interval_cycles <= 0;
            first_completion_wall <= 0;
            last_done_seen <= 0;
        end else begin
            if (clearing) begin
                if (clear_address == 255)
                    clearing <= 0;
                else
                    clear_address <= clear_address + 1'b1;
            end
            if (core_error && capture_active)
                fault <= 1;
            if (capture_active) begin
                wall_cycles <= wall_cycles + 1'b1;
                if (enc_busy) enc_cycles <= enc_cycles + 1'b1;
                if (dec_busy) dec_cycles <= dec_cycles + 1'b1;
                if (enc_busy && dec_busy) overlap_cycles <= overlap_cycles + 1'b1;
                if (pack_busy) pack_cycles <= pack_cycles + 1'b1;
                if (history_reset) reset_count <= reset_count + 1'b1;
                if (&wall_cycles) fault <= 1;
            end
            if (dec_start && !clearing && !ready && !last_done_seen) begin
                if (warmups < WARMUP_FRAMES) begin
                    warmups <= warmups + 1'b1;
                end else begin
                    frame_selected <= 1;
                    capture_active <= 1;
                end
            end
            if (op_start && frame_selected) begin
                if (op_active || op_index < FIRST_OP || op_index > LAST_OP)
                    fault <= 1;
                op_active <= 1;
                active_op <= op_index;
                op_cycles <= 0;
                tokens <= 0;
                input_wait <= 0;
                capacity_wait <= 0;
            end
            // A short history op can finish while the previous frame's LCC
            // record is still being accumulated. Queue it without stalling PL.
            if (!serial_busy && pending_valid) begin
                update_values <= pending_values;
                update_address <= pending_address;
                update_field <= 0;
                update_phase <= 0;
                serial_busy <= 1;
                pending_valid <= 0;
            end
            if (op_active) begin
                op_cycles <= op_cycles + 1'b1;
                if (token_events[0]) tokens <= tokens + 1'b1;
                if (token_events[1]) input_wait <= input_wait + 1'b1;
                if (token_events[2]) capacity_wait <= capacity_wait + 1'b1;
                if (&op_cycles) fault <= 1;
                if (op_done) begin
                    op_active <= 0;
                    if ((serial_busy && pending_valid) || active_op != op_index) begin
                        fault <= 1;
                    end else begin
                        pending_values <= {
                            capacity_wait + {31'd0, token_events[2]},
                            input_wait + {31'd0, token_events[1]},
                            tokens + {31'd0, token_events[0]},
                            conv_metrics,
                            op_cycles + 32'd1
                        };
                        pending_address <= {active_op, 3'b000};
                        pending_valid <= 1;
                    end
                end
            end
            if (serial_busy) begin
                case (update_phase)
                    0: update_phase <= 1;
                    1: begin
                        sum_reg <= sum_wide[31:0];
                        if (sum_wide[32]) fault <= 1;
                        update_phase <= 2;
                    end
                    2: begin
                        if (update_field == 7) begin
                            serial_busy <= 0;
                        end else begin
                            update_address <= update_address + 1'b1;
                            update_field <= update_field + 1'b1;
                            update_values <= update_values >> 32;
                            update_phase <= 0;
                        end
                    end
                    default: fault <= 1;
                endcase
            end
            if (dec_done && frame_selected) begin
                frame_selected <= 0;
                samples <= samples + 1'b1;
                if (samples == 0)
                    first_completion_wall <= wall_cycles;
                if (samples == SAMPLE_FRAMES - 1) begin
                    interval_cycles <= wall_cycles - first_completion_wall;
                    capture_active <= 0;
                    last_done_seen <= 1;
                end
            end
            if (last_done_seen && !serial_busy && !pending_valid && !op_active)
                ready <= 1;
        end
    end
endmodule
