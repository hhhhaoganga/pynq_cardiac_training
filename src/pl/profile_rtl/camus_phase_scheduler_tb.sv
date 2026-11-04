`timescale 1ns/1ps

module camus_phase_scheduler_tb;
    logic clk=0, rst=1, start=0;
    logic enc_op_done=0, dec_op_done=0;
    logic enc_op_error=0, dec_op_error=0;
    logic [31:0] input_base=32'h1000_0000, mask_base=32'h1100_0000;
    logic [31:0] skip_base=32'h1200_0000, scratch_base=32'h1300_0000;
    logic enc_op_start, dec_op_start;
    logic [2:0] enc_op_kind, dec_op_kind;
    logic [4:0] enc_op_index, dec_op_index, enc_layer_index, dec_layer_index;
    logic [31:0] enc_source_address, enc_source_b_address, enc_dest_address;
    logic [31:0] dec_source_address, dec_source_b_address, dec_dest_address;
    logic [8:0] enc_height,enc_width,enc_tile_rows,dec_height,dec_width,dec_tile_rows;
    logic [3:0] enc_input_groups,enc_output_groups,dec_input_groups,dec_output_groups;
    logic [3:0] enc_stored_output_groups,dec_stored_output_groups;
    logic enc_kernel_3x3,dec_kernel_3x3;
    logic [9:0] enc_weight_base,dec_weight_base;
    logic [5:0] enc_parameter_base,dec_parameter_base;
    logic [6:0] enc_tokens_per_output_group,dec_tokens_per_output_group;
    logic enc_relu_enable,dec_relu_enable;
    logic [19:0] enc_input_row_words,dec_input_row_words;
    logic [31:0] enc_input_row_bytes,enc_input_tile_stride_bytes,enc_output_row_bytes;
    logic [31:0] dec_input_row_bytes,dec_input_tile_stride_bytes,dec_output_row_bytes;
    logic enc_busy,enc_done,enc_error,dec_busy,dec_done,dec_error;
    logic [63:0] enc_cycle_count,dec_cycle_count;
    logic enc_done_seen=0, dec_done_seen=0;
    integer enc_launches=0, dec_launches=0, enc_convs=0, dec_convs=0;

    always #5 clk=~clk;
    always_ff @(posedge clk) begin
        enc_op_done <= enc_op_start;
        dec_op_done <= dec_op_start;
        if (enc_done) enc_done_seen <= 1'b1;
        if (dec_done) dec_done_seen <= 1'b1;
        if (enc_op_start) begin enc_launches<=enc_launches+1; if(enc_op_kind==0) enc_convs<=enc_convs+1; end
        if (dec_op_start) begin dec_launches<=dec_launches+1; if(dec_op_kind==0) dec_convs<=dec_convs+1; end
    end

    camus_phase_scheduler #(.FIRST_OP(0),.LAST_OP(10)) enc (
        .clk,.rst,.start,.op_done(enc_op_done),.op_error(enc_op_error),
        .input_base,.mask_base,.skip_base,.scratch_base,
        .op_start(enc_op_start),.op_kind(enc_op_kind),.op_index(enc_op_index),
        .layer_index(enc_layer_index),.source_address(enc_source_address),
        .source_b_address(enc_source_b_address),.dest_address(enc_dest_address),
        .height(enc_height),.width(enc_width),.tile_rows(enc_tile_rows),
        .input_groups(enc_input_groups),.output_groups(enc_output_groups),
        .stored_output_groups(enc_stored_output_groups),
        .kernel_3x3(enc_kernel_3x3),.weight_base(enc_weight_base),
        .parameter_base(enc_parameter_base),
        .tokens_per_output_group(enc_tokens_per_output_group),
        .relu_enable(enc_relu_enable),.input_row_words(enc_input_row_words),
        .input_row_bytes(enc_input_row_bytes),
        .input_tile_stride_bytes(enc_input_tile_stride_bytes),
        .output_row_bytes(enc_output_row_bytes),.busy(enc_busy),.done(enc_done),
        .error(enc_error),.cycle_count(enc_cycle_count));

    camus_phase_scheduler #(.FIRST_OP(11),.LAST_OP(28)) dec (
        .clk,.rst,.start,.op_done(dec_op_done),.op_error(dec_op_error),
        .input_base,.mask_base,.skip_base,.scratch_base,
        .op_start(dec_op_start),.op_kind(dec_op_kind),.op_index(dec_op_index),
        .layer_index(dec_layer_index),.source_address(dec_source_address),
        .source_b_address(dec_source_b_address),.dest_address(dec_dest_address),
        .height(dec_height),.width(dec_width),.tile_rows(dec_tile_rows),
        .input_groups(dec_input_groups),.output_groups(dec_output_groups),
        .stored_output_groups(dec_stored_output_groups),
        .kernel_3x3(dec_kernel_3x3),.weight_base(dec_weight_base),
        .parameter_base(dec_parameter_base),
        .tokens_per_output_group(dec_tokens_per_output_group),
        .relu_enable(dec_relu_enable),.input_row_words(dec_input_row_words),
        .input_row_bytes(dec_input_row_bytes),
        .input_tile_stride_bytes(dec_input_tile_stride_bytes),
        .output_row_bytes(dec_output_row_bytes),.busy(dec_busy),.done(dec_done),
        .error(dec_error),.cycle_count(dec_cycle_count));

    initial begin
        repeat(4) @(posedge clk);
        @(negedge clk); rst=0; start=1;
        @(negedge clk); start=0;
        wait(enc_done_seen && dec_done_seen);
        @(negedge clk);
        if(enc_error || dec_error || enc_launches!=11 || dec_launches!=18
                || enc_convs!=8 || dec_convs!=11)
            $fatal(1,"scheduler summary enc=%0d/%0d dec=%0d/%0d errors=%b%b",
                   enc_launches,enc_convs,dec_launches,dec_convs,enc_error,dec_error);
        $display("PASS camus_phase_scheduler encoder_ops=%0d decoder_ops=%0d",
                 enc_launches,dec_launches);
        $finish;
    end
endmodule
