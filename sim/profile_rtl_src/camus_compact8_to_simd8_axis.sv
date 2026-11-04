`timescale 1ns/1ps

// Expands a compact UINT8 raster stream into the frozen SIMD8 DDR layout.
// Each input byte becomes one 64-bit word with the gray value in lane 0.
module camus_compact8_to_simd8_axis (
    input logic clk,
    input logic rst,
    input logic s_valid,
    output logic s_ready,
    input logic [127:0] s_data,
    input logic [15:0] s_keep,
    input logic s_last,
    output logic m_valid,
    input logic m_ready,
    output logic [63:0] m_data,
    output logic m_last,
    output logic error
);
    logic beat_valid;
    logic [127:0] beat_data;
    logic beat_last;
    logic [4:0] byte_count;
    logic [3:0] byte_index;
    logic output_fire,beat_finishing;

    function automatic [4:0] keep_count(input logic [15:0] keep);
        integer i;
        begin
            keep_count=0;
            for(i=0;i<16;i=i+1)
                keep_count=keep_count+keep[i];
        end
    endfunction

    function automatic logic keep_is_contiguous(input logic [15:0] keep);
        integer i;
        logic saw_zero;
        begin
            saw_zero=1'b0;
            keep_is_contiguous=1'b1;
            for(i=0;i<16;i=i+1) begin
                if(!keep[i]) saw_zero=1'b1;
                else if(saw_zero) keep_is_contiguous=1'b0;
            end
        end
    endfunction

    assign m_valid=beat_valid;
    assign m_data={56'd0,beat_data[byte_index*8 +: 8]};
    assign m_last=beat_last&&(byte_index+1'b1==byte_count);
    assign output_fire=m_valid&&m_ready;
    assign beat_finishing=output_fire&&(byte_index+1'b1==byte_count);
    assign s_ready=!beat_valid||beat_finishing;

    always_ff @(posedge clk) begin
        if(rst) begin
            beat_valid<=1'b0;beat_data<=0;beat_last<=1'b0;
            byte_count<=0;byte_index<=0;error<=1'b0;
        end else begin
            if(output_fire) begin
                if(byte_index+1'b1==byte_count) begin
                    beat_valid<=1'b0;
                    byte_index<=0;
                end else begin
                    byte_index<=byte_index+1'b1;
                end
            end
            if(s_valid&&s_ready) begin
                beat_data<=s_data;
                beat_last<=s_last;
                byte_count<=keep_count(s_keep);
                byte_index<=0;
                beat_valid<=keep_count(s_keep)!=0;
                if(keep_count(s_keep)==0||!keep_is_contiguous(s_keep))
                    error<=1'b1;
            end
        end
    end
endmodule
