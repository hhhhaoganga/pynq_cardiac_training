`timescale 1ns/1ps

// Simulation-only shared DDR model for the encoder and decoder DataMovers.
module camus_dual_datamover_ddr_model #(
    parameter integer MEM_BYTES=12*1024*1024
) (
    input logic clk,input logic rst,
    input logic enc_mm2s_cmd_valid,output logic enc_mm2s_cmd_ready,
    input logic [71:0] enc_mm2s_cmd_data,
    output logic enc_mm2s_sts_valid,input logic enc_mm2s_sts_ready,
    output logic [7:0] enc_mm2s_sts_data,
    output logic enc_mm2s_valid,input logic enc_mm2s_ready,
    output logic [127:0] enc_mm2s_data,output logic [15:0] enc_mm2s_keep,
    output logic enc_mm2s_last,
    input logic enc_s2mm_cmd_valid,output logic enc_s2mm_cmd_ready,
    input logic [71:0] enc_s2mm_cmd_data,
    output logic enc_s2mm_sts_valid,input logic enc_s2mm_sts_ready,
    output logic [7:0] enc_s2mm_sts_data,
    input logic enc_s2mm_valid,output logic enc_s2mm_ready,
    input logic [127:0] enc_s2mm_data,input logic [15:0] enc_s2mm_keep,
    input logic enc_s2mm_last,

    input logic dec_mm2s_cmd_valid,output logic dec_mm2s_cmd_ready,
    input logic [71:0] dec_mm2s_cmd_data,
    output logic dec_mm2s_sts_valid,input logic dec_mm2s_sts_ready,
    output logic [7:0] dec_mm2s_sts_data,
    output logic dec_mm2s_valid,input logic dec_mm2s_ready,
    output logic [127:0] dec_mm2s_data,output logic [15:0] dec_mm2s_keep,
    output logic dec_mm2s_last,
    input logic dec_s2mm_cmd_valid,output logic dec_s2mm_cmd_ready,
    input logic [71:0] dec_s2mm_cmd_data,
    output logic dec_s2mm_sts_valid,input logic dec_s2mm_sts_ready,
    output logic [7:0] dec_s2mm_sts_data,
    input logic dec_s2mm_valid,output logic dec_s2mm_ready,
    input logic [127:0] dec_s2mm_data,input logic [15:0] dec_s2mm_keep,
    input logic dec_s2mm_last,
    output logic error
);
    logic [7:0] mem[0:MEM_BYTES-1];
    logic er_active,ew_active,dr_active,dw_active;
    logic [31:0] er_addr,ew_addr,dr_addr,dw_addr;
    logic [31:0] er_remaining,ew_remaining,dr_remaining,dw_remaining;
    logic [3:0] er_tag,ew_tag,dr_tag,dw_tag;
    integer i;

    function automatic [127:0] read_beat(input logic [31:0] address);
        integer k;
        begin
            read_beat=0;
            for(k=0;k<16;k=k+1)
                if(address+k<MEM_BYTES)
                    read_beat[k*8 +: 8]=mem[address+k];
        end
    endfunction

    function automatic [15:0] keep_for(input logic [31:0] remaining);
        logic [16:0] mask;
        begin
            if(remaining>=16) keep_for=16'hffff;
            else begin
                mask=(17'd1<<remaining)-1'b1;
                keep_for=mask[15:0];
            end
        end
    endfunction

    function automatic [4:0] count_keep(input logic [15:0] keep);
        integer k;
        begin
            count_keep=0;
            for(k=0;k<16;k=k+1) count_keep=count_keep+keep[k];
        end
    endfunction

    function automatic logic keep_contiguous(input logic [15:0] keep);
        integer k;
        logic zero_seen;
        begin
            zero_seen=0;keep_contiguous=1;
            for(k=0;k<16;k=k+1) begin
                if(!keep[k]) zero_seen=1;
                else if(zero_seen) keep_contiguous=0;
            end
        end
    endfunction

    assign enc_mm2s_cmd_ready=!er_active&&!enc_mm2s_valid&&!enc_mm2s_sts_valid;
    assign enc_s2mm_cmd_ready=!ew_active&&!enc_s2mm_sts_valid;
    assign enc_s2mm_ready=ew_active;
    assign dec_mm2s_cmd_ready=!dr_active&&!dec_mm2s_valid&&!dec_mm2s_sts_valid;
    assign dec_s2mm_cmd_ready=!dw_active&&!dec_s2mm_sts_valid;
    assign dec_s2mm_ready=dw_active;

    always_ff @(posedge clk) begin
        if(rst) begin
            er_active<=0;ew_active<=0;dr_active<=0;dw_active<=0;
            er_addr<=0;ew_addr<=0;dr_addr<=0;dw_addr<=0;
            er_remaining<=0;ew_remaining<=0;dr_remaining<=0;dw_remaining<=0;
            er_tag<=0;ew_tag<=0;dr_tag<=0;dw_tag<=0;
            enc_mm2s_sts_valid<=0;enc_mm2s_sts_data<=0;
            enc_mm2s_valid<=0;enc_mm2s_data<=0;enc_mm2s_keep<=0;
            enc_mm2s_last<=0;enc_s2mm_sts_valid<=0;enc_s2mm_sts_data<=0;
            dec_mm2s_sts_valid<=0;dec_mm2s_sts_data<=0;
            dec_mm2s_valid<=0;dec_mm2s_data<=0;dec_mm2s_keep<=0;
            dec_mm2s_last<=0;dec_s2mm_sts_valid<=0;dec_s2mm_sts_data<=0;
            error<=0;
        end else begin
            if(enc_mm2s_sts_valid&&enc_mm2s_sts_ready)
                enc_mm2s_sts_valid<=0;
            if(enc_s2mm_sts_valid&&enc_s2mm_sts_ready)
                enc_s2mm_sts_valid<=0;
            if(dec_mm2s_sts_valid&&dec_mm2s_sts_ready)
                dec_mm2s_sts_valid<=0;
            if(dec_s2mm_sts_valid&&dec_s2mm_sts_ready)
                dec_s2mm_sts_valid<=0;

            if(enc_mm2s_cmd_valid&&enc_mm2s_cmd_ready) begin
                er_addr<=enc_mm2s_cmd_data[63:32];
                er_remaining<=enc_mm2s_cmd_data[22:0];
                er_tag<=enc_mm2s_cmd_data[67:64];
                er_active<=enc_mm2s_cmd_data[22:0]!=0;
                if(enc_mm2s_cmd_data[22:0]==0
                        ||enc_mm2s_cmd_data[63:32]
                            +enc_mm2s_cmd_data[22:0]>MEM_BYTES)
                    error<=1'b1;
            end
            if(er_active&&!enc_mm2s_valid) begin
                enc_mm2s_data<=read_beat(er_addr);
                enc_mm2s_keep<=keep_for(er_remaining);
                enc_mm2s_last<=er_remaining<=16;
                enc_mm2s_valid<=1'b1;
            end
            if(enc_mm2s_valid&&enc_mm2s_ready) begin
                enc_mm2s_valid<=1'b0;
                if(er_remaining<=16) begin
                    er_active<=0;enc_mm2s_sts_valid<=1;
                    enc_mm2s_sts_data<={1'b1,3'b000,er_tag};
                end else begin
                    er_addr<=er_addr+16;er_remaining<=er_remaining-16;
                end
            end

            if(dec_mm2s_cmd_valid&&dec_mm2s_cmd_ready) begin
                dr_addr<=dec_mm2s_cmd_data[63:32];
                dr_remaining<=dec_mm2s_cmd_data[22:0];
                dr_tag<=dec_mm2s_cmd_data[67:64];
                dr_active<=dec_mm2s_cmd_data[22:0]!=0;
                if(dec_mm2s_cmd_data[22:0]==0
                        ||dec_mm2s_cmd_data[63:32]
                            +dec_mm2s_cmd_data[22:0]>MEM_BYTES)
                    error<=1'b1;
            end
            if(dr_active&&!dec_mm2s_valid) begin
                dec_mm2s_data<=read_beat(dr_addr);
                dec_mm2s_keep<=keep_for(dr_remaining);
                dec_mm2s_last<=dr_remaining<=16;
                dec_mm2s_valid<=1'b1;
            end
            if(dec_mm2s_valid&&dec_mm2s_ready) begin
                dec_mm2s_valid<=1'b0;
                if(dr_remaining<=16) begin
                    dr_active<=0;dec_mm2s_sts_valid<=1;
                    dec_mm2s_sts_data<={1'b1,3'b000,dr_tag};
                end else begin
                    dr_addr<=dr_addr+16;dr_remaining<=dr_remaining-16;
                end
            end

            if(enc_s2mm_cmd_valid&&enc_s2mm_cmd_ready) begin
                ew_addr<=enc_s2mm_cmd_data[63:32];
                ew_remaining<=enc_s2mm_cmd_data[22:0];
                ew_tag<=enc_s2mm_cmd_data[67:64];
                ew_active<=enc_s2mm_cmd_data[22:0]!=0;
                if(enc_s2mm_cmd_data[22:0]==0
                        ||enc_s2mm_cmd_data[63:32]
                            +enc_s2mm_cmd_data[22:0]>MEM_BYTES)
                    error<=1'b1;
            end
            if(enc_s2mm_valid&&enc_s2mm_ready) begin
                for(i=0;i<16;i=i+1)
                    if(enc_s2mm_keep[i]&&ew_addr+i<MEM_BYTES)
                        mem[ew_addr+i]<=enc_s2mm_data[i*8 +: 8];
                if(!keep_contiguous(enc_s2mm_keep)
                        ||count_keep(enc_s2mm_keep)==0
                        ||count_keep(enc_s2mm_keep)>ew_remaining
                        ||enc_s2mm_last!=(count_keep(enc_s2mm_keep)==ew_remaining)) begin
                    error<=1'b1;enc_s2mm_sts_data<={1'b1,3'b001,ew_tag};
                end else enc_s2mm_sts_data<={1'b1,3'b000,ew_tag};
                if(enc_s2mm_last||count_keep(enc_s2mm_keep)>=ew_remaining) begin
                    ew_active<=0;enc_s2mm_sts_valid<=1;
                end else begin
                    ew_addr<=ew_addr+count_keep(enc_s2mm_keep);
                    ew_remaining<=ew_remaining-count_keep(enc_s2mm_keep);
                end
            end

            if(dec_s2mm_cmd_valid&&dec_s2mm_cmd_ready) begin
                dw_addr<=dec_s2mm_cmd_data[63:32];
                dw_remaining<=dec_s2mm_cmd_data[22:0];
                dw_tag<=dec_s2mm_cmd_data[67:64];
                dw_active<=dec_s2mm_cmd_data[22:0]!=0;
                if(dec_s2mm_cmd_data[22:0]==0
                        ||dec_s2mm_cmd_data[63:32]
                            +dec_s2mm_cmd_data[22:0]>MEM_BYTES)
                    error<=1'b1;
            end
            if(dec_s2mm_valid&&dec_s2mm_ready) begin
                for(i=0;i<16;i=i+1)
                    if(dec_s2mm_keep[i]&&dw_addr+i<MEM_BYTES)
                        mem[dw_addr+i]<=dec_s2mm_data[i*8 +: 8];
                if(!keep_contiguous(dec_s2mm_keep)
                        ||count_keep(dec_s2mm_keep)==0
                        ||count_keep(dec_s2mm_keep)>dw_remaining
                        ||dec_s2mm_last!=(count_keep(dec_s2mm_keep)==dw_remaining)) begin
                    error<=1'b1;dec_s2mm_sts_data<={1'b1,3'b001,dw_tag};
                end else dec_s2mm_sts_data<={1'b1,3'b000,dw_tag};
                if(dec_s2mm_last||count_keep(dec_s2mm_keep)>=dw_remaining) begin
                    dw_active<=0;dec_s2mm_sts_valid<=1;
                end else begin
                    dw_addr<=dw_addr+count_keep(dec_s2mm_keep);
                    dw_remaining<=dw_remaining-count_keep(dec_s2mm_keep);
                end
            end
        end
    end
endmodule
