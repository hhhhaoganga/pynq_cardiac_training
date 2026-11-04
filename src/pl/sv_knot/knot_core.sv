`timescale 1ns/1ps
// Row microprogram engine. Memory command addresses are 64-bit BEAT addresses.
// DMA commands and data use independent ready/valid handshakes. The AXI wrapper
// must split transfers at 4 KiB/AXI burst boundaries without changing this stream.
module knot_core (
    input wire clk, reset, start, input wire [31:0] program_address,
    output reg busy, done, fault,
    output wire rd_cmd_valid, input wire rd_cmd_ready,
    output wire [31:0] rd_addr, output wire [15:0] rd_count,
    input wire rd_valid, output wire rd_ready, input wire [63:0] rd_data,
    output wire wr_cmd_valid, input wire wr_cmd_ready,
    output wire [31:0] wr_addr, output wire [15:0] wr_count,
    output wire wr_valid, input wire wr_ready, output wire [63:0] wr_data,
    output reg check_valid, output reg [7:0] check_block,
    output reg [31:0] check_address,check_count,
    output reg [63:0] cycles
);
    localparam HALT=0,LOAD=1,STORE=2,PW=3,DW=4,STEM=5,POOL=6,CHECK=7;
    localparam PIN=0,LB=1,RES=2,IMG=3,WT=4,WD=5,PP=6,PD=7,OUT=8,DWB=9;
    typedef enum logic[5:0] {IDLE,F_CMD,F_DATA,DISPATCH,L_CMD,L_DATA,ZERO,
        S_CMD,S_PREF,S_DATA,P_PAR,P_PWAIT,P_RUN,P_FLUSH,D_PAR,D_PWAIT,
        D_WGET,D_WWAIT,D_RUN,D_DRAIN,D_QREAD,D_QWAIT,D_QFEED,D_QFLUSH,
        ST_REQ,ST_WAIT,ST_SAVE,ST_WRITE,POOL_REQ,POOL_WAIT,POOL_CALC,POOL_WRITE,
        FINISH} state_t;
    state_t state;
    reg [31:0] c[0:15];
    reg [31:0] pc;
    reg [15:0] pos;
    reg [2:0] bank_count;
    reg [10:0] tile_count;
    reg [8:0] x,og,ig;
    reg [1:0] quarter;
    reg plane;
    reg [15:0] out_index,res_index,in_index,weight_index;
    reg [5:0] prefetch;
    reg [5:0] wait_count;
    reg [63:0] param[0:15];
    reg [15:0] group_weight_base;
    reg [1:0] ky;
    reg [9:0] col;
    reg [8:0] dw_x;reg signed [10:0] line_index;
    reg [1:0] stride_phase;
    reg [239:0] dw_weights;
    reg [127:0] win0,win1;
    reg [1:0] img_row,img_col;
    reg stem_valid,stem_ok,stem_pixel_half;reg [9:0] stem_col;
    reg [31:0] stem_win0[0:2],stem_win1[0:2];
    reg [1:0] stem_left;reg [8:0] stem_write_address;
    wire [31:0] stem_pixel[0:2];

    reg [255:0] patch;
    reg [127:0] pool_left[0:7];
    reg [127:0] pool_value;
    reg pool_half;
    reg [9:0] pool_out;

    wire read_fire=rd_valid&&rd_ready;
    assign rd_cmd_valid=(state==F_CMD)||(state==L_CMD);
    assign rd_addr=(state==F_CMD)?pc:c[1];
    assign rd_count=(state==F_CMD)?16'd8:c[2][15:0];
    assign rd_ready=(state==F_DATA)||(state==L_DATA);
    assign wr_cmd_valid=state==S_CMD;
    assign wr_addr=c[1];assign wr_count=c[2][15:0];
    assign wr_valid=state==S_DATA;

    // All memories are instantiated with one synchronous read and one write port.
    // 128-bit vectors are two independent 64-bit banks; writeback is never 512-bit.
    reg pin_we[0:1],lb_we[0:7],res_we[0:1],dwb_we[0:1];
    reg [8:0] pin_wa, pin_ra, res_wa,res_ra,dwb_wa,dwb_ra;
    reg [8:0] lb_wa,lb_ra;
    reg [63:0] pin_wdata[0:1],res_wdata[0:1],dwb_wdata[0:1],lb_wdata;
    wire [63:0] pin_rd[0:1],res_rd[0:1],dwb_rd[0:1],lb_rd[0:7];
    wire [127:0] pin_vec={pin_rd[1],pin_rd[0]},res_vec={res_rd[1],res_rd[0]},dwb_vec={dwb_rd[1],dwb_rd[0]};
    reg [1:0] lb_select,lb_select_d;
    wire [127:0] lb_vec={lb_rd[2*lb_select_d+1],lb_rd[2*lb_select_d]};
    for(genvar b=0;b<2;b=b+1) begin: vector_ram
        knot_ram #(.DEPTH(512)) pin_mem(clk,pin_we[b],pin_wa,pin_wdata[b],pin_ra,pin_rd[b]);
        knot_ram #(.DEPTH(512)) res_mem(clk,res_we[b],res_wa,res_wdata[b],res_ra,res_rd[b]);
        knot_ram #(.DEPTH(512)) dwb_mem(clk,dwb_we[b],dwb_wa,dwb_wdata[b],dwb_ra,dwb_rd[b]);
    end
    for(genvar b=0;b<8;b=b+1) begin: line_ram
        knot_ram #(.DEPTH(512)) mem(clk,lb_we[b],lb_wa,lb_wdata,lb_ra,lb_rd[b]);
    end
    reg wt_we[0:4];reg [10:0] wt_wa,wt_ra;reg [63:0] wt_wdata;
    wire [63:0] wt_rd[0:4];
    for(genvar b=0;b<5;b=b+1) begin: weight_ram
        knot_weight_bank mem(clk,wt_we[b],wt_wa,wt_wdata,wt_ra,wt_rd[b]);
    end
    wire [319:0] wt_vec={wt_rd[4],wt_rd[3],wt_rd[2],wt_rd[1],wt_rd[0]};
    reg wd_we,pp_we,pd_we,img_we,out_we,acc_we;
    reg [7:0] wd_wa,wd_ra;
    reg [9:0] pp_wa,pp_ra;
    reg [8:0] pd_wa,pd_ra,img_wa,img_ra,out_wa,out_ra,acc_wa,acc_ra;
    reg [63:0] wd_wdata,pp_wdata,pd_wdata,img_wdata,out_wdata;
    reg [383:0] acc_wdata;
    wire [63:0] wd_rd,pp_rd,pd_rd,out_rd;
    wire [63:0] img_rd[0:2];
    for(genvar r=0;r<3;r=r+1)assign stem_pixel[r]=stem_ok?img_rd[r][stem_pixel_half*32+:32]:32'b0;
    wire [383:0] acc_rd;
    knot_ram #(.DEPTH(256)) dw_weights_ram(clk,wd_we,wd_wa,wd_wdata,wd_ra,wd_rd);
    knot_ram #(.DEPTH(1024)) pw_params_ram(clk,pp_we,pp_wa,pp_wdata,pp_ra,pp_rd);
    knot_ram #(.DEPTH(512)) dw_params_ram(clk,pd_we,pd_wa,pd_wdata,pd_ra,pd_rd);
    for(genvar r=0;r<3;r=r+1) begin: stem_rows
        knot_ram #(.DEPTH(256)) mem(clk,img_we&&(c[4][1:0]==r),img_wa[7:0],img_wdata,img_ra[7:0],img_rd[r]);
    end
    knot_ram #(.DEPTH(512)) output_ram(clk,out_we,out_wa,out_wdata,out_ra,out_rd);
    knot_ram #(.W(384),.DEPTH(512)) accumulator_ram(clk,acc_we,acc_wa,acc_wdata,acc_ra,acc_rd);
    reg store_half;
    assign wr_data=(c[3]==DWB)?(pos[0]?dwb_rd[1]:dwb_rd[0]):out_rd;

    // PW RAM request metadata is registered through exactly one RAM cycle.
    reg pw_v,pw_first,pw_last,pw_plane;
    reg [1:0] pw_quarter;
    reg [31:0] pw_tag;
    wire pw_done;
    wire [383:0] pw_result;
    wire [31:0] pw_out_tag;
    wire [127:0] pw_input=c[7][1:0]==0?pin_vec:dwb_vec;
    knot_pw_array pw_array(clk,reset,pw_v,pw_first,pw_last,pw_plane,c[9][0],pw_quarter,
        pw_input,wt_vec,pw_tag,pw_done,pw_result,pw_out_tag);

    // DW sliding window. Accumulator read starts with the window token; the
    // window and tag are registered once to align with synchronous partial sums.
    reg dw_read_v,dw_read_ok,dw_read_emit,dw_read_first;
    reg [8:0] dw_read_addr;
    reg dw_v,dw_first;
    reg [383:0] dw_window;
    reg [8:0] dw_address;
    wire dw_done;
    wire [383:0] dw_result;
    wire [8:0] dw_out_addr;
    wire [127:0] dw_new=dw_read_ok?lb_vec:128'b0;
    knot_dw_array dw_array(clk,reset,dw_v,dw_first,c[9][0],dw_window,acc_rd,dw_weights,
        dw_address,dw_done,dw_result,dw_out_addr);

    // One shared requantizer. Parameters are local registers for this output
    // channel group, loaded once before scanning its pixels.
    reg [383:0] drain_acc;
    reg [15:0] drain_addr,drain_res;
    reg [1:0] drain_target;
    reg [1:0] drain_slot;
    reg [1:0] drain_phase;
    reg [191:0] q_acc,q_bias;
    reg [255:0] q_mult;
    reg [47:0] q_shift;
    reg [63:0] q_res;
    reg [15:0] q_tag;
    reg q_valid;
    wire q_done;
    wire [63:0] q_result;
    wire [15:0] q_out_tag;
    wire is_dw=c[0]==DW;
    wire r_enable=!is_dw&&(c[12][1:0]!=0);
    wire signed [15:0] q_lo=is_dw?c[10][15:0]:c[10][15:0];
    wire signed [15:0] q_hi=is_dw?c[11][15:0]:c[11][15:0];
    knot_quant8 quantizer(clk,reset,q_valid,q_acc,q_bias,q_mult,q_shift,q_res,
        r_enable,c[12][2],c[13],c[14],q_lo,q_hi,c[15][15:0],c[15][31:16],q_tag,
        q_done,q_result,q_out_tag);
    // Head writes sign-extended biased accumulators in eight 64-bit beats.
    reg [511:0] head_data;
    reg [3:0] head_left;
    reg [8:0] head_address;

    integer b,l;
    integer li,ix,iy,sl;
    reg [127:0] pv;
    reg signed [8:0] aa,bb,ll;
    reg signed [8:0] mv;
    reg [127:0] vertical;
    reg [127:0] pooled;
    always @* begin
        for(integer n=0;n<16;n=n+1) begin end
        pin_wa=0;pin_ra=0;res_wa=0;res_ra=0;dwb_wa=0;dwb_ra=0;
        lb_wa=0;lb_ra=0;lb_select=0;lb_wdata=0;
        for(integer n=0;n<2;n=n+1) begin
            pin_we[n]=0;res_we[n]=0;dwb_we[n]=0;
            pin_wdata[n]=0;res_wdata[n]=0;dwb_wdata[n]=0;
        end
        for(integer n=0;n<8;n=n+1) lb_we[n]=0;
        for(integer n=0;n<5;n=n+1) wt_we[n]=0;
        wt_wa=tile_count;wt_ra=weight_index;wt_wdata=rd_data;
        wd_we=0;wd_wa=pos;wd_ra=(og*3+ky)*4+prefetch;wd_wdata=rd_data;
        pp_we=0;pp_wa=c[4]+pos;pp_ra=c[6]+og*16+prefetch;pp_wdata=rd_data;
        pd_we=0;pd_wa=pos;pd_ra=og*16+prefetch;pd_wdata=rd_data;
        img_we=0;img_wa=pos;img_ra=0;img_wdata=rd_data;
        out_we=0;out_wa=0;out_ra=pos;out_wdata=0;
        acc_we=dw_done;acc_wa=dw_out_addr;acc_wdata=dw_result;acc_ra=dw_read_addr;
        li=0;ix=0;iy=0;sl=0;pv=0;aa=0;bb=0;ll=0;mv=0;vertical=0;pooled=0;
        if(state==L_DATA&&read_fire) begin
            case(c[3])
            PIN: begin pin_we[pos[0]]=1;pin_wa=pos>>1;pin_wdata[pos[0]]=rd_data;end
            LB: begin lb_we[c[4][11:10]*2+pos[0]]=1;lb_wa=pos>>1;lb_wdata=rd_data;end
            RES: begin res_we[pos[0]]=1;res_wa=pos>>1;res_wdata[pos[0]]=rd_data;end
            IMG: img_we=1;
            WT: wt_we[bank_count]=1;
            WD: wd_we=1;
            PP: pp_we=1;
            PD: pd_we=1;
            default: begin end
            endcase
        end
        if(state==ZERO) begin img_we=1;img_wdata=0;end
        if(state==P_RUN) begin pin_ra=in_index+ig;dwb_ra=in_index+ig;end
        if(state==D_RUN) begin
            lb_ra=line_index;
            lb_select=(c[2]+ky)&3;
        end
        if(state==D_QREAD||state==D_QWAIT||state==D_QFEED) acc_ra=x+(state==D_QFEED&&pool_half);
        if(state==ST_REQ||state==ST_WAIT||state==ST_SAVE) begin
            ix=$signed({1'b0,col})-$signed(c[3]);
            img_ra=ix>>1;
        end
        if(stem_left!=0) begin
            pin_wa=stem_write_address;
            for(integer n=0;n<2;n=n+1) begin pin_we[n]=1;pin_wdata[n]=patch[(stem_left==1)*128+n*64+:64];end
        end
        if(state==POOL_REQ||state==POOL_WAIT||state==POOL_CALC) begin
            pin_ra=in_index;res_ra=in_index;
            for(integer n=0;n<16;n=n+1) begin
                aa=$signed({c[3][0]&pin_vec[n*8+7],pin_vec[n*8+:8]});
                bb=$signed({c[3][0]&res_vec[n*8+7],res_vec[n*8+:8]});
                ll=$signed({c[3][0]&pool_left[og][n*8+7],pool_left[og][n*8+:8]});
                mv=aa>bb?aa:bb;vertical[n*8+:8]=mv;pooled[n*8+:8]=ll>mv?ll:mv;
            end
        end
        if(state==POOL_WRITE) begin
            res_wa=pool_out;
            for(integer n=0;n<2;n=n+1) begin res_we[n]=1;res_wdata[n]=pool_value[n*64+:64];end
        end
        if(state==S_PREF) begin out_ra=pos;dwb_ra=pos>>1;end
        if(state==S_DATA) begin out_ra=pos+(wr_ready?1:0);dwb_ra=(pos+(wr_ready?1:0))>>1;end
        // The residual vector is fetched on drain phase 1, consumed on 2 and 3.
        if(drain_phase!=0) res_ra=drain_res;
        if(q_done) begin
            case(q_out_tag[15:14])
            0: begin lb_we[q_out_tag[13:12]*2+q_out_tag[0]]=1;
                lb_wa=q_out_tag[9:1];lb_wdata=q_result;end
            1: begin out_we=1;out_wa=q_out_tag[8:0];out_wdata=q_result;end
            2: begin dwb_we[q_out_tag[0]]=1;dwb_wa=q_out_tag[9:1];dwb_wdata[q_out_tag[0]]=q_result;end
            default: begin end
            endcase
        end
        if(head_left!=0) begin out_we=1;out_wa=head_address;out_wdata=head_data[63:0];end
    end

    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;busy<=0;done<=0;fault<=0;cycles<=0;check_valid<=0;
            pw_v<=0;dw_read_v<=0;dw_v<=0;drain_phase<=0;q_valid<=0;head_left<=0;stem_valid<=0;stem_left<=0;
            pc<=0;pos<=0;prefetch<=0;og<=0;ig<=0;x<=0;quarter<=0;plane<=0;
            in_index<=0;weight_index<=0;out_index<=0;res_index<=0;
            wait_count<=0;ky<=0;col<=0;dw_x<=0;stride_phase<=0;pool_half<=0;
        end else begin
            done<=0;check_valid<=0;pw_v<=0;dw_read_v<=0;dw_v<=0;q_valid<=0;stem_valid<=0;
            if(busy) cycles<=cycles+1;
            lb_select_d<=lb_select;
            // Sliding window shifts on every column including explicit padding.
            if(dw_read_v) begin
                win0<=win1;win1<=dw_new;
                dw_v<=dw_read_emit;dw_first<=dw_read_first;
                dw_window<={dw_new,win1,win0};dw_address<=dw_read_addr;
            end
            if(pw_done) begin
                if(c[7]==2) begin
                    for(integer n=0;n<16;n=n+1) begin
                        head_data[n*32+:32]<=$signed(pw_result[n*24+:24])+$signed(param[n][23:0]);
                    end
                    head_address<=pw_out_tag[15:0]*8;head_left<=8;
                end else begin
                    drain_acc<=pw_result;drain_addr<=pw_out_tag[15:0];drain_res<=pw_out_tag[31:16];
                    drain_target<=c[7]==0?0:1;drain_slot<=c[8][1:0];drain_phase<=1;
                end
            end
            if(stem_left!=0)begin stem_left<=stem_left-1;stem_write_address<=stem_write_address+1;end
            if(stem_valid) begin
                for(integer r=0;r<3;r=r+1)begin
                    stem_win0[r]<=stem_win1[r];stem_win1[r]<=stem_pixel[r];
                    if(stem_col>=2&&!stem_col[0])begin
                        for(integer ch=0;ch<3;ch=ch+1)begin
                            patch[((r*3+0)*3+ch)*8+:8]<=stem_win0[r][ch*8+:8];
                            patch[((r*3+1)*3+ch)*8+:8]<=stem_win1[r][ch*8+:8];
                            patch[((r*3+2)*3+ch)*8+:8]<=stem_pixel[r][ch*8+:8];
                        end
                    end
                end
                if(stem_col>=2&&!stem_col[0])begin
                    stem_left<=2;stem_write_address<=stem_col-2;
                end
            end
            if(head_left!=0) begin head_data<=head_data>>64;head_address<=head_address+1;head_left<=head_left-1;end
            if(drain_phase==1) drain_phase<=2;
            if(drain_phase==2||drain_phase==3) begin
                q_valid<=1;
                q_acc<=drain_acc[(drain_phase==3)*192+:192];
                for(integer n=0;n<8;n=n+1) begin
                    q_bias[n*24+:24]<=param[n+(drain_phase==3?8:0)][23:0];
                    q_mult[n*32+:32]<=param[n+(drain_phase==3?8:0)][55:24];
                    q_shift[n*6+:6]<=param[n+(drain_phase==3?8:0)][61:56];
                end
                q_res<=res_vec[(drain_phase==3)*64+:64];
                q_tag<={drain_target,drain_slot,2'b0,drain_addr[8:0],(drain_phase==3)};
                drain_phase<=drain_phase==2?3:0;
            end
            case(state)
            IDLE: if(start) begin busy<=1;fault<=0;pc<=program_address;cycles<=0;state<=F_CMD;end
            F_CMD: if(rd_cmd_ready) begin state<=F_DATA;pos<=0;end
            F_DATA: if(read_fire) begin
                c[2*pos]<=rd_data[31:0];c[2*pos+1]<=rd_data[63:32];pos<=pos+1;
                if(pos==7) begin pc<=pc+8;state<=DISPATCH;end
            end
            DISPATCH: begin
                pos<=0;x<=0;og<=0;ig<=0;prefetch<=0;bank_count<=0;tile_count<=0;
                case(c[0])
                HALT:state<=FINISH;
                LOAD:state<=(c[3]==IMG&&c[4][31])?ZERO:L_CMD;
                STORE:state<=S_CMD;
                PW:begin state<=P_PAR;group_weight_base<=c[5];end
                DW:begin state<=D_PAR;ky<=0;end
                STEM:begin state<=ST_REQ;col<=0;patch<=0;
                    for(integer r=0;r<3;r=r+1)begin stem_win0[r]<=0;stem_win1[r]<=0;end
                end
                POOL:begin state<=POOL_REQ;pool_out<=0;in_index<=0;end
                CHECK:begin check_valid<=1;check_block<=c[1];check_address<=c[2];check_count<=c[3];state<=F_CMD;end
                default:begin fault<=1;state<=FINISH;end
                endcase
            end
            L_CMD:if(rd_cmd_ready)state<=L_DATA;
            L_DATA:if(read_fire) begin
                pos<=pos+1;
                if(bank_count==4)begin bank_count<=0;tile_count<=tile_count+1;end else bank_count<=bank_count+1;
                if(pos+1==c[2])state<=F_CMD;
            end
            ZERO:begin pos<=pos+1;if(pos+1==c[2])state<=F_CMD;end
            S_CMD:if(wr_cmd_ready)begin state<=S_PREF;pos<=0;end
            S_PREF:begin store_half<=pos[0];state<=S_DATA;end
            S_DATA:if(wr_ready)begin
                pos<=pos+1;if(pos+1==c[2])state<=F_CMD;
            end
            P_PAR,D_PAR:begin
                if(prefetch!=0)param[prefetch-1]<=state==P_PAR?pp_rd:pd_rd;
                if(prefetch==15)state<=state==P_PAR?P_PWAIT:D_PWAIT;
                else prefetch<=prefetch+1;
            end
            P_PWAIT:begin
                param[15]<=pp_rd;x<=0;ig<=0;quarter<=0;plane<=0;
                in_index<=0;out_index<=og;res_index<=og;weight_index<=group_weight_base;
                state<=P_RUN;
            end
            P_RUN:begin
                pw_v<=1;pw_first<=ig==0&&quarter==0&&!plane;
                pw_last<=ig+1==c[2]&&quarter==3&&(plane+1==c[4]);
                pw_plane<=plane;pw_quarter<=quarter;pw_tag<={res_index,out_index};
                weight_index<=weight_index+1;
                if(plane+1==c[4])begin
                    plane<=0;
                    if(quarter==3)begin
                        quarter<=0;
                        if(ig+1==c[2])begin
                            ig<=0;x<=x+1;in_index<=in_index+c[2];out_index<=out_index+c[3];
                            if(c[12][1:0]!=3||x[0])res_index<=res_index+c[3];
                            weight_index<=group_weight_base;
                            if(x+1==c[1])begin state<=P_FLUSH;wait_count<=0;end
                        end else ig<=ig+1;
                    end else quarter<=quarter+1;
                end else plane<=plane+1;
            end
            P_FLUSH:begin
                wait_count<=wait_count+1;
                if(wait_count==(og+1==c[3]?16:7))begin
                    if(og+1==c[3])state<=F_CMD;
                    else begin og<=og+1;group_weight_base<=group_weight_base+(c[4][1]?(c[2][8:0]<<3):(c[2][8:0]<<2));prefetch<=0;state<=P_PAR;end
                end
            end
            D_PWAIT:begin param[15]<=pd_rd;ky<=0;prefetch<=0;state<=D_WGET;end
            D_WGET:begin
                if(prefetch!=0)dw_weights[(prefetch-1)*64+:64]<=wd_rd;
                if(prefetch==3)state<=D_WWAIT;else prefetch<=prefetch+1;
            end
            D_WWAIT:begin
                dw_weights[239:192]<=wd_rd[47:0];line_index<=$signed({1'b0,og})-(c[12][0]?$signed({6'b0,c[7][4:0]}):11'sd0);col<=0;dw_x<=0;stride_phase<=0;win0<=0;win1<=0;state<=D_RUN;
            end
            D_RUN:begin
                dw_read_v<=1;
                dw_read_ok<=c[14][ky]&&(col>=c[12][8:0])&&(col<c[6][8:0]+c[12][8:0]);
                line_index<=line_index+$signed({6'b0,c[7][4:0]});
                dw_read_emit<=col+1>=c[3]&&stride_phase==0;
                dw_read_first<=ky==0;dw_read_addr<=dw_x;
                if(col+1>=c[3])begin
                    if(stride_phase==0)dw_x<=dw_x+1;
                    stride_phase<=stride_phase+1==c[4]?0:stride_phase+1;
                end
                if(col+1==c[13][9:0])begin
                    if(ky+1==c[3])begin state<=D_DRAIN;wait_count<=0;end
                    else begin ky<=ky+1;prefetch<=0;state<=D_WGET;end
                end
                else col<=col+1;
            end
            D_DRAIN:begin
                wait_count<=wait_count+1;
                if(wait_count==5)begin
                    if(ky+1==c[3])begin x<=0;state<=D_QREAD;end
                    else begin ky<=ky+1;prefetch<=0;state<=D_WGET;end
                end
            end
            D_QREAD:state<=D_QWAIT;
            D_QWAIT:begin pool_half<=0;out_index<=og;state<=D_QFEED;end
            D_QFEED:begin
                q_valid<=1;q_acc<=acc_rd[pool_half*192+:192];q_res<=0;
                for(integer n=0;n<8;n=n+1) begin
                    q_bias[n*24+:24]<=param[n+(pool_half?8:0)][23:0];
                    q_mult[n*32+:32]<=param[n+(pool_half?8:0)][55:24];
                    q_shift[n*6+:6]<=param[n+(pool_half?8:0)][61:56];
                end
                q_tag<={2'b10,4'b0,out_index[8:0],pool_half};
                pool_half<=!pool_half;
                if(pool_half)begin
                    if(x+1==c[8])begin
                        if(og+1==c[7])begin state<=D_QFLUSH;wait_count<=0;end
                        else begin og<=og+1;prefetch<=0;state<=D_PAR;end
                    end
                    else begin x<=x+1;out_index<=out_index+c[7][4:0];end
                end
            end
            D_QFLUSH:begin
                wait_count<=wait_count+1;
                if(wait_count==9)begin
                    if(og+1==c[7])state<=F_CMD;
                    else begin og<=og+1;prefetch<=0;state<=D_PAR;end
                end
            end
            ST_REQ:begin
                stem_valid<=1;stem_col<=col;
                stem_pixel_half<=($signed({1'b0,col})-$signed(c[3]))&1;
                stem_ok<=($signed({1'b0,col})-$signed(c[3])>=0)&&
                    ($signed({1'b0,col})-$signed(c[3])<$signed(c[1]));
                if(col+1==(c[2]-1)*2+3)begin state<=ST_SAVE;wait_count<=0;end
                else col<=col+1;
            end
            ST_SAVE:begin wait_count<=wait_count+1;if(wait_count==4)state<=F_CMD;end
            POOL_REQ:state<=POOL_WAIT;
            POOL_WAIT:state<=POOL_CALC;
            POOL_CALC:begin
                in_index<=in_index+1;
                if(!x[0])pool_left[og]<=vertical;else pool_value<=pooled;
                if(x[0])state<=POOL_WRITE;
                else if(og+1==c[2])begin og<=0;x<=x+1;state<=POOL_REQ;end
                else begin og<=og+1;state<=POOL_REQ;end
            end
            POOL_WRITE:begin
                pool_out<=pool_out+1;
                if(og+1==c[2])begin
                    og<=0;x<=x+1;
                    if(x+1==c[1])state<=F_CMD;else state<=POOL_REQ;
                end else begin og<=og+1;state<=POOL_REQ;end
            end
            FINISH:begin busy<=0;done<=1;state<=IDLE;end
            default:begin fault<=1;state<=FINISH;end
            endcase
        end
    end
endmodule
