`timescale 1ns/1ps

module camus_stream_pipeline_core_tb #(
    parameter integer FRAMES=1,
    parameter bit CHECK_INTERMEDIATE=1'b0,
    parameter bit COMPARE_GOLDEN=1'b1
);
    localparam integer PIXELS=256*256;
    localparam integer MEM_BYTES=12*1024*1024;
    localparam [31:0] RAW_BASE=32'h0080_0000;
    localparam [31:0] MASK_BASE=32'h0090_0000;
    logic clk=0,rst=1,clear_history=0;
    logic frame_valid=0,frame_ready;
    logic [31:0] frame_input_base=0,frame_mask_base=0,frame_id=0;
    logic [31:0] slot0_padded_base=32'h0001_0000;
    logic [31:0] slot0_skip_base=32'h0010_0000;
    logic [31:0] slot0_scratch_base=32'h0020_0000;
    logic [31:0] slot1_padded_base=32'h0040_0000;
    logic [31:0] slot1_skip_base=32'h0050_0000;
    logic [31:0] slot1_scratch_base=32'h0060_0000;
    logic [31:0] watchdog_limit=32'd20000000;
    logic [31:0] post_base=32'h0070_0000;

    logic enc_mm2s_cmd_valid,enc_mm2s_cmd_ready;
    logic [71:0] enc_mm2s_cmd_data;
    logic enc_mm2s_sts_valid,enc_mm2s_sts_ready;
    logic [7:0] enc_mm2s_sts_data;
    logic enc_mm2s_valid,enc_mm2s_ready;
    logic [127:0] enc_mm2s_data;
    logic [15:0] enc_mm2s_keep;
    logic enc_mm2s_last;
    logic enc_s2mm_cmd_valid,enc_s2mm_cmd_ready;
    logic [71:0] enc_s2mm_cmd_data;
    logic enc_s2mm_sts_valid,enc_s2mm_sts_ready;
    logic [7:0] enc_s2mm_sts_data;
    logic enc_s2mm_valid,enc_s2mm_ready;
    logic [127:0] enc_s2mm_data;
    logic [15:0] enc_s2mm_keep;
    logic enc_s2mm_last;

    logic dec_mm2s_cmd_valid,dec_mm2s_cmd_ready;
    logic [71:0] dec_mm2s_cmd_data;
    logic dec_mm2s_sts_valid,dec_mm2s_sts_ready;
    logic [7:0] dec_mm2s_sts_data;
    logic dec_mm2s_valid,dec_mm2s_ready;
    logic [127:0] dec_mm2s_data;
    logic [15:0] dec_mm2s_keep;
    logic dec_mm2s_last;
    logic dec_s2mm_cmd_valid,dec_s2mm_cmd_ready;
    logic [71:0] dec_s2mm_cmd_data;
    logic dec_s2mm_sts_valid,dec_s2mm_sts_ready;
    logic [7:0] dec_s2mm_sts_data;
    logic dec_s2mm_valid,dec_s2mm_ready;
    logic [127:0] dec_s2mm_data;
    logic [15:0] dec_s2mm_keep;
    logic dec_s2mm_last;

    logic result_valid,result_ready=1;
    logic [31:0] result_mask_base,result_frame_id;
    logic busy,error,ddr_error;
    logic [63:0] frames_accepted,frames_completed;
    logic [63:0] pack_cycle_count,enc_cycle_count,dec_cycle_count;
    logic [4:0] enc_current_op,dec_current_op;
    logic [1:0] history_count;
    logic [50:0] area_counts;
    logic [7:0] expected_masks[0:3*PIXELS-1];
    string frames_path,masks_path,result_dump_path;
    integer frames_fd,masks_fd,result_dump_fd,value,index,one_frame,pixel;
    integer received=0,mismatches=0,encoders_checked=0;
    longint unsigned simulation_cycles=0;
    longint unsigned last_result_cycle=0;
    longint unsigned result_interval=0;

    function automatic [63:0] expected_hash(input integer layer);
        case(layer)
            0: expected_hash=64'h66a82bd8742b3f9a;
            1: expected_hash=64'h2b788ee3c18d8520;
            2: expected_hash=64'h5bc3f68afe0d9195;
            3: expected_hash=64'h8e71057efd83a5b8;
            4: expected_hash=64'h82b621e7e786e538;
            5: expected_hash=64'hcf9b170b2490cb9a;
            6: expected_hash=64'h8077f4b0168b1c72;
            7: expected_hash=64'h35d6d6406de00d1a;
            8: expected_hash=64'h202e0a29ce814b65;
            // Pointwise projection is evaluated before nearest in PL. This is
            // bit-equivalent but stores the compact low-resolution tensor.
            9: expected_hash=64'hdf361fdc429e3051;
            10: expected_hash=64'h8148fa8794c1146a;
            11: expected_hash=64'h429cec97f0fa45fd;
            12: expected_hash=64'hddbd736a8fd55809;
            13: expected_hash=64'hd37353f0b9e7ad59;
            14: expected_hash=64'h69c76ff15a40a749;
            15: expected_hash=64'h8702388b8068078e;
            16: expected_hash=64'h68959d5771688ff3;
            17: expected_hash=64'h1b1ced827ee39b4f;
            18: expected_hash=64'h43bb6158881378de;
            default: expected_hash=0;
        endcase
    endfunction

    task automatic check_ddr_layer(
        input integer layer,input logic [31:0] base,
        input integer one_height,input integer one_width,
        input integer channels,input integer stored_channels
    );
        integer y,x,c,offset,dump_fd;
        reg [63:0] hash;
        begin
            hash=64'hcbf29ce484222325;
            for(y=0;y<one_height;y=y+1)
                for(x=0;x<one_width;x=x+1)
                    for(c=0;c<channels;c=c+1) begin
                        offset=base+(y*one_width+x)*stored_channels+c;
                        hash=(hash^ddr.mem[offset])*64'h00000100000001b3;
                    end
            $display("LAYER_HASH layer=%0d got=%h expected=%h",
                layer,hash,expected_hash(layer));
            if(hash!==expected_hash(layer)) begin
                dump_fd=$fopen("rtl_layer_debug.bin","wb");
                for(y=0;y<one_height;y=y+1)
                    for(x=0;x<one_width;x=x+1)
                        for(c=0;c<channels;c=c+1) begin
                            offset=base+(y*one_width+x)*stored_channels+c;
                            $fwrite(dump_fd,"%c",ddr.mem[offset]);
                        end
                $fclose(dump_fd);
                $fatal(1,"first layer mismatch layer=%0d",layer);
            end
        end
    endtask

    task automatic check_first_history_bank;
        integer word,lane;
        reg [63:0] hash;
        reg [7:0] one_byte;
        begin
            hash=64'hcbf29ce484222325;
            for(word=0;word<4096;word=word+1)
                for(lane=0;lane<8;lane=lane+1) begin
                    one_byte=dut.u_core.u_history.u_history
                        .g_history_bank[0].u_bank.memory[word][lane*8 +: 8];
                    hash=(hash^one_byte)*64'h00000100000001b3;
                end
            $display("HISTORY_HASH layer=7 got=%h expected=%h",
                hash,expected_hash(7));
            if(hash!==expected_hash(7))
                $fatal(1,"first history bank mismatch");
        end
    endtask

    always #5 clk=~clk;
    camus_stream_pipeline_core dut(.*);
    camus_dual_datamover_ddr_model #(.MEM_BYTES(MEM_BYTES)) ddr(.*,.error(ddr_error));

    always @(posedge clk)
        if(rst) simulation_cycles<=0;
        else simulation_cycles<=simulation_cycles+1;

    initial begin
        if(FRAMES<1||FRAMES>3) $fatal(1,"FRAMES must be 1..3");
        if(!$value$plusargs("FRAMES_FILE=%s",frames_path)
                ||!$value$plusargs("MASKS_FILE=%s",masks_path))
            $fatal(1,"missing frame/mask file plusargs");
        frames_fd=$fopen(frames_path,"rb");
        masks_fd=$fopen(masks_path,"rb");
        if(frames_fd==0||masks_fd==0) $fatal(1,"cannot open golden files");
        for(one_frame=0;one_frame<3;one_frame=one_frame+1) begin
            for(pixel=0;pixel<PIXELS;pixel=pixel+1) begin
                value=$fgetc(frames_fd);
                if(value<0) $fatal(1,"short frames file");
                ddr.mem[RAW_BASE+one_frame*PIXELS+pixel]=value[7:0];
                value=$fgetc(masks_fd);
                if(value<0) $fatal(1,"short masks file");
                expected_masks[one_frame*PIXELS+pixel]=value[7:0];
            end
        end
        $fclose(frames_fd);$fclose(masks_fd);
    end

    always @(posedge clk) begin
        if(CHECK_INTERMEDIATE&&dut.core_enc_done&&encoders_checked==0) begin
            check_first_history_bank();
            encoders_checked=1;
        end
        if(CHECK_INTERMEDIATE&&FRAMES==1&&dut.u_core.u_encoder.conv_done
                &&dut.u_core.u_encoder.layer_index!=7)
            check_ddr_layer(dut.u_core.u_encoder.layer_index,
                dut.u_core.u_encoder.dest_address,
                dut.u_core.u_encoder.height,dut.u_core.u_encoder.width,
                dut.u_core.u_encoder.output_groups*4,
                dut.u_core.u_encoder.stored_output_groups*8);
        if(CHECK_INTERMEDIATE&&FRAMES==1&&dut.u_core.u_decoder.conv_done)
            check_ddr_layer(dut.u_core.u_decoder.layer_index,
                dut.u_core.u_decoder.dest_address,
                dut.u_core.u_decoder.height,dut.u_core.u_decoder.width,
                dut.u_core.u_decoder.output_groups*4,
                dut.u_core.u_decoder.stored_output_groups*8);
        if(result_valid&&result_ready) begin
            mismatches=0;
            result_interval=received==0?0:simulation_cycles-last_result_cycle;
            if(result_frame_id!==received)
                $fatal(1,"result order expected=%0d got=%0d",received,result_frame_id);
            if($value$plusargs("RESULT_DUMP_FILE=%s",result_dump_path)) begin
                result_dump_fd=$fopen(result_dump_path,"wb");
                if(result_dump_fd==0) $fatal(1,"cannot open result dump");
                for(index=0;index<PIXELS;index=index+1)
                    $fwrite(result_dump_fd,"%c",ddr.mem[result_mask_base+index]);
                $fclose(result_dump_fd);
            end
            for(index=0;index<PIXELS;index=index+1)
                if(ddr.mem[result_mask_base+index]
                        !==expected_masks[received*PIXELS+index])
                    mismatches=mismatches+1;
            $display("FRAME_RESULT id=%0d mismatch=%0d at_cycle=%0d interval=%0d enc_cycles=%0d dec_cycles=%0d history=%0d",
                received,mismatches,simulation_cycles,result_interval,
                enc_cycle_count,dec_cycle_count,history_count);
            if(COMPARE_GOLDEN&&mismatches!=0)
                $fatal(1,"mask mismatch frame=%0d count=%0d",
                    received,mismatches);
            if(received>0&&result_interval>4166667)
                $fatal(1,"24 FPS interval exceeded frame=%0d interval=%0d",
                    received,result_interval);
            last_result_cycle=simulation_cycles;
            received<=received+1;
        end
    end

    initial begin
        repeat(8) @(posedge clk);@(negedge clk);rst=0;
        for(one_frame=0;one_frame<FRAMES;one_frame=one_frame+1) begin
            while(!frame_ready) @(negedge clk);
            frame_input_base=RAW_BASE+one_frame*PIXELS;
            frame_mask_base=MASK_BASE+one_frame*PIXELS;
            frame_id=one_frame;frame_valid=1;
            @(negedge clk);frame_valid=0;
        end
        fork : finish_or_timeout
            begin
                wait(received==FRAMES);repeat(5) @(posedge clk);
                if(error||ddr_error||busy||frames_accepted!=FRAMES
                        ||frames_completed!=FRAMES)
                    $fatal(1,"summary core=%b ddr=%b busy=%b accepted=%0d completed=%0d",
                        error,ddr_error,busy,frames_accepted,frames_completed);
                $display("PASS camus_stream_pipeline_core frames=%0d",FRAMES);
            end
            begin repeat(30000000) @(posedge clk);
                $fatal(1,"full pipeline timeout enc_op=%0d dec_op=%0d accepted=%0d completed=%0d",
                    enc_current_op,dec_current_op,frames_accepted,frames_completed);
            end
        join_any
        disable finish_or_timeout;
        $finish;
    end
endmodule
