`timescale 1ns/1ps

module camus_frame_pipeline_controller_tb #(
    parameter integer FRAMES=6
);
    logic clk=0,rst=1;
    logic frame_valid=0,frame_ready;
    logic [31:0] frame_input_base=0,frame_mask_base=0,frame_id=0;
    logic [31:0] slot0_padded_base=32'h1000_0000;
    logic [31:0] slot0_skip_base=32'h1100_0000;
    logic [31:0] slot0_scratch_base=32'h1200_0000;
    logic [31:0] slot1_padded_base=32'h2000_0000;
    logic [31:0] slot1_skip_base=32'h2100_0000;
    logic [31:0] slot1_scratch_base=32'h2200_0000;
    logic pack_start,pack_done=0,pack_error=0;
    logic [31:0] pack_input_base,pack_output_base;
    logic enc_start,enc_done=0,enc_error=0;
    logic [31:0] enc_input_base,enc_skip_base,enc_scratch_base;
    logic dec_start,dec_done=0,dec_error=0;
    logic [31:0] dec_mask_base,dec_skip_base,dec_scratch_base;
    logic result_valid,result_ready=1;
    logic [31:0] result_mask_base,result_frame_id;
    logic encoder_dma_owner_pack,busy,error;
    logic [63:0] frames_accepted,frames_completed;
    integer cycle=0,send_id=0,recv_id=0;
    integer pack_timer=0,enc_timer=0,dec_timer=0;
    integer overlap_cycles=0;

    always #5 clk=~clk;
    camus_frame_pipeline_controller dut(.*);

    always @(posedge clk) begin
        if(!rst) cycle<=cycle+1;
        pack_done<=0;enc_done<=0;dec_done<=0;

        if(pack_start) begin
            if(pack_timer!=0||pack_output_base
                    !==(frame_id[0]?slot1_padded_base:slot0_padded_base))
                $fatal(1,"bad pack start id=%0d out=%h",frame_id,pack_output_base);
            pack_timer<=4;
        end else if(pack_timer>0) begin
            pack_timer<=pack_timer-1;
            if(pack_timer==1) pack_done<=1;
        end

        if(enc_start) begin
            if(enc_timer!=0) $fatal(1,"encoder overlap");
            if(!((enc_input_base===slot0_padded_base
                            &&enc_skip_base===slot0_skip_base
                            &&enc_scratch_base===slot0_scratch_base)
                    ||(enc_input_base===slot1_padded_base
                            &&enc_skip_base===slot1_skip_base
                            &&enc_scratch_base===slot1_scratch_base)))
                $fatal(1,"encoder slot address mismatch");
            enc_timer<=11;
        end else if(enc_timer>0) begin
            enc_timer<=enc_timer-1;
            if(enc_timer==1) enc_done<=1;
        end

        if(dec_start) begin
            if(dec_timer!=0) $fatal(1,"decoder overlap");
            if(dec_mask_base!==32'h4000_0000+recv_id*32'h0010_0000)
                $fatal(1,"decoder order/base mismatch recv=%0d base=%h",
                    recv_id,dec_mask_base);
            if(recv_id[0]&&!(dec_skip_base===slot1_skip_base
                    &&dec_scratch_base===slot1_scratch_base))
                $fatal(1,"decoder slot1 address mismatch");
            if(!recv_id[0]&&!(dec_skip_base===slot0_skip_base
                    &&dec_scratch_base===slot0_scratch_base))
                $fatal(1,"decoder slot0 address mismatch");
            dec_timer<=17;
        end else if(dec_timer>0) begin
            dec_timer<=dec_timer-1;
            if(dec_timer==1) dec_done<=1;
        end

        if((pack_timer>0||enc_timer>0)&&dec_timer>0)
            overlap_cycles<=overlap_cycles+1;

        if(result_valid&&result_ready) begin
            if(result_frame_id!==recv_id
                    ||result_mask_base!==32'h4000_0000
                        +recv_id*32'h0010_0000)
                $fatal(1,"result mismatch expected=%0d got=%0d base=%h",
                    recv_id,result_frame_id,result_mask_base);
            recv_id<=recv_id+1;
        end
    end

    initial begin
        repeat(5) @(posedge clk);@(negedge clk);rst=0;
        while(send_id<FRAMES) begin
            @(negedge clk);
            if(frame_ready) begin
                frame_valid=1;frame_id=send_id;
                frame_input_base=32'h3000_0000+send_id*32'h0010_0000;
                frame_mask_base=32'h4000_0000+send_id*32'h0010_0000;
                send_id=send_id+1;
            end else frame_valid=0;
        end
        @(negedge clk);frame_valid=0;
        fork : finish_or_timeout
            begin
                wait(recv_id==FRAMES);repeat(3) @(posedge clk);
                if(error||busy||frames_accepted!=FRAMES
                        ||frames_completed!=FRAMES||overlap_cycles==0)
                    $fatal(1,"summary err=%b busy=%b accepted=%0d completed=%0d overlap=%0d",
                        error,busy,frames_accepted,frames_completed,overlap_cycles);
                $display("PASS camus_frame_pipeline frames=%0d cycles=%0d overlap=%0d",
                    FRAMES,cycle,overlap_cycles);
            end
            begin repeat(1000) @(posedge clk);$fatal(1,"pipeline timeout");end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
