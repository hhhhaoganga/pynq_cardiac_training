`timescale 1ns/1ps

module camus_u16_axis128_packer (
    input logic clk,input logic rst,
    input logic s_valid,output logic s_ready,
    input logic [15:0] s_data,input logic s_last,
    output logic m_valid,input logic m_ready,
    output logic [127:0] m_data,output logic [15:0] m_keep,
    output logic m_last,output logic error
);
    logic [127:0] buffer;
    logic [3:0] count;
    logic pending_valid,pending_last;
    logic [15:0] pending_keep;
    logic [127:0] pending_data;
    logic output_slot;

    assign output_slot=!pending_valid||m_ready;
    assign s_ready=output_slot;
    assign m_valid=pending_valid;
    assign m_data=pending_data;
    assign m_keep=pending_keep;
    assign m_last=pending_last;

    always_ff @(posedge clk) begin
        if(rst) begin
            buffer<=0;count<=0;pending_valid<=0;pending_last<=0;
            pending_keep<=0;pending_data<=0;error<=0;
        end else begin
            if(pending_valid&&m_ready) pending_valid<=0;
            if(s_valid&&s_ready) begin
                buffer[count*16 +:16]<=s_data;
                if(count==7||s_last) begin
                    pending_data<=buffer;
                    pending_data[count*16 +:16]<=s_data;
                    pending_keep<=16'hffff>>((7-count)*2);
                    pending_last<=s_last;
                    pending_valid<=1;
                    buffer<=0;count<=0;
                end else count<=count+1'b1;
            end
        end
    end
endmodule
