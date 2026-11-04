`timescale 1ns/1ps

module camus_nearest_concat_case #(
    parameter integer PROJECT_CHANNELS = 4,
    parameter integer SKIP_CHANNELS = 4,
    parameter integer LOW_WIDTH = 2,
    parameter integer LOW_HEIGHT = 2,
    parameter integer TILE_LOW_ROWS = 1,
    parameter integer CASE_ID = 0
) (
    output logic case_done
);
    localparam integer HIGH_WIDTH = LOW_WIDTH * 2;
    localparam integer HIGH_HEIGHT = LOW_HEIGHT * 2;
    localparam integer A_GROUPS = (PROJECT_CHANNELS + 7) / 8;
    localparam integer B_GROUPS = (SKIP_CHANNELS + 7) / 8;
    localparam integer OUT_GROUPS = (PROJECT_CHANNELS + SKIP_CHANNELS + 7) / 8;
    localparam integer TOTAL_OUTPUT_WORDS = HIGH_WIDTH * HIGH_HEIGHT * OUT_GROUPS;
    localparam integer TOTAL_TILES = (LOW_HEIGHT + TILE_LOW_ROWS - 1) / TILE_LOW_ROWS;
    localparam integer TOTAL_A_WORDS = LOW_WIDTH * LOW_HEIGHT * A_GROUPS;
    localparam integer TOTAL_B_WORDS = HIGH_WIDTH * HIGH_HEIGHT * B_GROUPS;

    logic clk=0, rst=1, start=0;
    logic [31:0] project_base_bytes=32'h00001000, skip_base_bytes=32'h00200000;
    logic [31:0] output_base_bytes=32'h00400000;
    logic [8:0] low_width=LOW_WIDTH, low_height=LOW_HEIGHT, tile_low_rows=TILE_LOW_ROWS;
    logic [5:0] project_channels=PROJECT_CHANNELS, skip_channels=SKIP_CHANNELS;
    logic signed [31:0] project_multiplier=32'sd536870912;
    logic signed [6:0] project_shift=29;
    logic signed [31:0] skip_multiplier=32'sd536870912;
    logic signed [6:0] skip_shift=29;
    logic [31:0] watchdog_limit=20000000;
    logic m_axis_mm2s_cmd_tvalid, m_axis_mm2s_cmd_tready=1;
    logic [71:0] m_axis_mm2s_cmd_tdata;
    logic s_axis_mm2s_sts_tvalid=0, s_axis_mm2s_sts_tready;
    logic [7:0] s_axis_mm2s_sts_tdata=0;
    logic s_axis_mm2s_tvalid, s_axis_mm2s_tready;
    logic [127:0] s_axis_mm2s_tdata;
    logic [15:0] s_axis_mm2s_tkeep=16'hffff;
    logic s_axis_mm2s_tlast;
    logic m_axis_s2mm_cmd_tvalid, m_axis_s2mm_cmd_tready=1;
    logic [71:0] m_axis_s2mm_cmd_tdata;
    logic s_axis_s2mm_sts_tvalid=0, s_axis_s2mm_sts_tready;
    logic [7:0] s_axis_s2mm_sts_tdata=0;
    logic m_axis_s2mm_tvalid, m_axis_s2mm_tready;
    logic [127:0] m_axis_s2mm_tdata;
    logic [15:0] m_axis_s2mm_tkeep;
    logic m_axis_s2mm_tlast;
    logic busy, done, error;
    logic [63:0] cycle_count;
    logic [15:0] tiles_completed;

    logic [63:0] project_words[0:TOTAL_A_WORDS-1];
    logic [63:0] skip_words[0:TOTAL_B_WORDS-1];
    integer cycle=0, mm_word_base=0, mm_beat=0, mm_beats=0;
    integer mm_cmd_count=0, s2_cmd_count=0, output_word=0, output_stall=0;
    integer mm_status_delay=0, s2_status_delay=0;
    logic mm_active=0, s2_active=0;
    logic [3:0] mm_tag=0, s2_tag=0;
    logic mm_is_skip=0;

    always #5 clk=~clk;
    assign m_axis_s2mm_tready=(cycle%9)!=4;
    assign s_axis_mm2s_tvalid=mm_active;
    assign s_axis_mm2s_tdata=mm_is_skip
        ? {skip_words[mm_word_base+mm_beat*2+1],skip_words[mm_word_base+mm_beat*2]}
        : {project_words[mm_word_base+mm_beat*2+1],project_words[mm_word_base+mm_beat*2]};
    assign s_axis_mm2s_tlast=mm_active && mm_beat==mm_beats-1;

    camus_nearest_concat_datamover_executor #(.CACHE_DEPTH(4096)) dut(.*);

    function automatic [63:0] make_group(
        input integer pixel, input integer group, input integer bias,
        input integer channels
    );
        integer lane, channel;
        begin
            make_group=0;
            for(lane=0;lane<8;lane=lane+1) begin
                channel=group*8+lane;
                if(channel<channels)
                    make_group[lane*8 +: 8]=bias+pixel*channels+channel;
            end
        end
    endfunction

    function automatic [63:0] expected_word(input integer index);
        integer x,y,pixel,group,a_pixel;
        logic [63:0] a,b;
        begin
            pixel=index/OUT_GROUPS;
            group=index%OUT_GROUPS;
            x=pixel%HIGH_WIDTH;
            y=pixel/HIGH_WIDTH;
            a_pixel=(y>>1)*LOW_WIDTH+(x>>1);
            if(PROJECT_CHANNELS==4 && SKIP_CHANNELS==4) begin
                a=make_group(a_pixel,0,10,PROJECT_CHANNELS);
                b=make_group(pixel,0,100,SKIP_CHANNELS);
                expected_word={b[31:0],a[31:0]};
            end else if(group<A_GROUPS) begin
                expected_word=make_group(a_pixel,group,10,PROJECT_CHANNELS);
            end else begin
                expected_word=make_group(pixel,group-A_GROUPS,100,SKIP_CHANNELS);
            end
        end
    endfunction

    integer i;
    initial begin
        case_done=0;
        for(i=0;i<16;i=i+1) project_words[i]=0;
        for(i=0;i<64;i=i+1) skip_words[i]=0;
        for(i=0;i<LOW_WIDTH*LOW_HEIGHT*A_GROUPS;i=i+1)
            project_words[i]=make_group(i/A_GROUPS,i%A_GROUPS,10,PROJECT_CHANNELS);
        for(i=0;i<HIGH_WIDTH*HIGH_HEIGHT*B_GROUPS;i=i+1)
            skip_words[i]=make_group(i/B_GROUPS,i%B_GROUPS,100,SKIP_CHANNELS);
    end

    always @(posedge clk) begin
        if(!rst) cycle<=cycle+1;
        if(!rst && m_axis_s2mm_tvalid && !m_axis_s2mm_tready)
            output_stall<=output_stall+1;
        if(m_axis_mm2s_cmd_tvalid&&m_axis_mm2s_cmd_tready) begin
            mm_active<=1; mm_beat<=0; mm_tag<=m_axis_mm2s_cmd_tdata[67:64];
            if(m_axis_mm2s_cmd_tdata[63:32]>=32'h00001000
                    && m_axis_mm2s_cmd_tdata[63:32]<32'h00200000) begin
                mm_is_skip<=0;
                mm_word_base<=(m_axis_mm2s_cmd_tdata[63:32]-32'h00001000)/8;
                if(m_axis_mm2s_cmd_tdata[22:0]!=TILE_LOW_ROWS*LOW_WIDTH*A_GROUPS*8)
                    $fatal(1,"case %0d bad A BTT %0d",CASE_ID,m_axis_mm2s_cmd_tdata[22:0]);
            end else if(m_axis_mm2s_cmd_tdata[63:32]>=32'h00200000
                    && m_axis_mm2s_cmd_tdata[63:32]<32'h00400000) begin
                mm_is_skip<=1;
                mm_word_base<=(m_axis_mm2s_cmd_tdata[63:32]-32'h00200000)/8;
                if(m_axis_mm2s_cmd_tdata[22:0]!=2*TILE_LOW_ROWS*HIGH_WIDTH*B_GROUPS*8)
                    $fatal(1,"case %0d bad B BTT %0d",CASE_ID,m_axis_mm2s_cmd_tdata[22:0]);
            end else $fatal(1,"case %0d bad MM2S address %h",CASE_ID,m_axis_mm2s_cmd_tdata[63:32]);
            mm_beats<=m_axis_mm2s_cmd_tdata[22:0]/16;
            mm_cmd_count<=mm_cmd_count+1;
        end
        if(s_axis_mm2s_tvalid&&s_axis_mm2s_tready) begin
            if(mm_beat==mm_beats-1) begin mm_active<=0; mm_status_delay<=3; end
            else mm_beat<=mm_beat+1;
        end
        if(mm_status_delay>0) begin
            mm_status_delay<=mm_status_delay-1;
            if(mm_status_delay==1) begin
                s_axis_mm2s_sts_tvalid<=1;
                s_axis_mm2s_sts_tdata<={1'b1,3'b000,mm_tag};
            end
        end else if(s_axis_mm2s_sts_tvalid&&s_axis_mm2s_sts_tready)
            s_axis_mm2s_sts_tvalid<=0;

        if(m_axis_s2mm_cmd_tvalid&&m_axis_s2mm_cmd_tready) begin
            if(m_axis_s2mm_cmd_tdata[63:32]!==32'h00400000
                    +s2_cmd_count*2*TILE_LOW_ROWS*HIGH_WIDTH*OUT_GROUPS*8
                    || m_axis_s2mm_cmd_tdata[22:0]!==2*TILE_LOW_ROWS*HIGH_WIDTH*OUT_GROUPS*8)
                $fatal(1,"case %0d bad S2MM command addr=%h btt=%0d",
                    CASE_ID,m_axis_s2mm_cmd_tdata[63:32],m_axis_s2mm_cmd_tdata[22:0]);
            s2_active<=1; s2_tag<=m_axis_s2mm_cmd_tdata[67:64];
            s2_cmd_count<=s2_cmd_count+1;
        end
        if(m_axis_s2mm_tvalid&&m_axis_s2mm_tready) begin
            if(!s2_active||m_axis_s2mm_tkeep!==16'hffff)
                $fatal(1,"case %0d bad S2MM data state/keep",CASE_ID);
            if(m_axis_s2mm_tdata[63:0]!==expected_word(output_word)
                    || m_axis_s2mm_tdata[127:64]!==expected_word(output_word+1))
                $fatal(1,"case %0d output mismatch word=%0d got=%h expected=%h/%h",
                    CASE_ID,output_word,m_axis_s2mm_tdata,
                    expected_word(output_word+1),expected_word(output_word));
            output_word<=output_word+2;
            if(m_axis_s2mm_tlast) begin s2_active<=0; s2_status_delay<=4; end
        end
        if(s2_status_delay>0) begin
            s2_status_delay<=s2_status_delay-1;
            if(s2_status_delay==1) begin
                s_axis_s2mm_sts_tvalid<=1;
                s_axis_s2mm_sts_tdata<={1'b1,3'b000,s2_tag};
            end
        end else if(s_axis_s2mm_sts_tvalid&&s_axis_s2mm_sts_tready)
            s_axis_s2mm_sts_tvalid<=0;
    end

    initial begin
        repeat(5) @(posedge clk); @(negedge clk); rst=0; start=1;
        @(negedge clk); start=0;
        fork : finish_or_timeout
            begin
                wait(done); @(negedge clk);
                if(error||busy||tiles_completed!=TOTAL_TILES||mm_cmd_count!=TOTAL_TILES*2
                        ||s2_cmd_count!=TOTAL_TILES||output_word!=TOTAL_OUTPUT_WORDS)
                    $fatal(1,"case %0d summary error=%b busy=%b tiles=%0d mm=%0d s2=%0d words=%0d",
                        CASE_ID,error,busy,tiles_completed,mm_cmd_count,s2_cmd_count,output_word);
                $display("PASS concat case=%0d channels=%0d+%0d words=%0d cycles=%0d no_stall=%0d",
                    CASE_ID,PROJECT_CHANNELS,SKIP_CHANNELS,output_word,cycle_count,
                    cycle_count-output_stall);
                case_done=1;
            end
            begin repeat(500000) @(posedge clk); $fatal(1,"case %0d timeout",CASE_ID); end
        join_any
        disable finish_or_timeout;
    end
endmodule

module camus_nearest_concat_datamover_executor_tb;
    logic done_4,done_8,done_16;
    camus_nearest_concat_case #(
        .PROJECT_CHANNELS(4),.SKIP_CHANNELS(4),.LOW_WIDTH(128),.LOW_HEIGHT(128),
        .TILE_LOW_ROWS(8),.CASE_ID(0)) case_4(.case_done(done_4));
    camus_nearest_concat_case #(
        .PROJECT_CHANNELS(8),.SKIP_CHANNELS(8),.LOW_WIDTH(64),.LOW_HEIGHT(64),
        .TILE_LOW_ROWS(16),.CASE_ID(1)) case_8(.case_done(done_8));
    camus_nearest_concat_case #(
        .PROJECT_CHANNELS(16),.SKIP_CHANNELS(16),.LOW_WIDTH(32),.LOW_HEIGHT(32),
        .TILE_LOW_ROWS(16),.CASE_ID(2)) case_16(.case_done(done_16));
    initial begin
        wait(done_4&&done_8&&done_16);
        $display("PASS camus_nearest_concat_datamover_executor all channel configurations");
        $finish;
    end
endmodule
