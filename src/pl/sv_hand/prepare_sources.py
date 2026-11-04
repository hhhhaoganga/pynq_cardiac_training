"""Create an isolated hand candidate from released knot control and reviewed arrays.

Run once. Never modifies the released knot source or implementation checkpoints.
"""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parent
KNOT = HERE.parent / 'sv_knot'
REVIEW = HERE.parent / 'sv_hand_review_20261008'


def main():
    rtl = HERE / 'rtl'
    rtl.mkdir(exist_ok=True)
    sources = {}
    for src in (KNOT / 'rtl').glob('*.sv'):
        sources[str(src.relative_to(HERE.parent))] = hashlib.sha256(src.read_bytes()).hexdigest()
        (rtl / src.name).write_text(src.read_text(), newline='\n')
    for src, name, old, new in [
        (REVIEW / 'pw_array_review.sv', 'knot_pw_array.sv', 'pw_array_review #(parameter integer NI=4)', 'knot_pw_array #(parameter integer NI=8)'),
        (REVIEW / 'dw5_array_review.sv', 'knot_dw_array.sv', 'dw5_array_review', 'knot_dw_array')]:
        sources[str(src.relative_to(HERE.parent))] = hashlib.sha256(src.read_bytes()).hexdigest()
        (rtl / name).write_text(src.read_text().replace(old, new), newline='\n')
    path = rtl / 'knot_core.sv'
    s = path.read_text()
    changes = [
        ('reg [2:0] bank_count;', 'reg [3:0] bank_count;\n    reg [3:0] pw_cooldown;\n    wire [10:0] pw_pixel_issues=c[4][1]?(c[2][8:0]<<2):(c[2][8:0]<<1);\n    wire [3:0] pw_min_spacing=c[7]==2?8:4;'),
        ('reg [1:0] ky;', 'reg [2:0] ky;'),
        ('reg [239:0] dw_weights;', 'reg [399:0] dw_weights;'),
        ('reg [127:0] win0,win1;', 'reg [127:0] win0,win1,win2,win3;'),
        ('lb_we[0:7]', 'lb_we[0:11]'), ('lb_rd[0:7]', 'lb_rd[0:11]'),
        ('reg [1:0] lb_select,lb_select_d;', 'reg [2:0] lb_select,lb_select_d;'),
        ('b<8;b=b+1) begin: line_ram', 'b<12;b=b+1) begin: line_ram'),
        ('wt_we[0:4]', 'wt_we[0:9]'), ('wt_rd[0:4]', 'wt_rd[0:9]'),
        ('b<5;b=b+1) begin: weight_ram', 'b<10;b=b+1) begin: weight_ram'),
        ('knot_weight_bank mem(clk,wt_we[b],wt_wa,wt_wdata,wt_ra,wt_rd[b]);', 'knot_ram #(.DEPTH(1024)) mem(clk,wt_we[b],wt_wa[9:0],wt_wdata,wt_ra[9:0],wt_rd[b]);'),
        ('wire [319:0] wt_vec={wt_rd[4],wt_rd[3],wt_rd[2],wt_rd[1],wt_rd[0]};', 'wire [639:0] wt_vec={wt_rd[9],wt_rd[8],wt_rd[7],wt_rd[6],wt_rd[5],wt_rd[4],wt_rd[3],wt_rd[2],wt_rd[1],wt_rd[0]};'),
        ('reg [7:0] wd_wa,wd_ra;', 'reg [10:0] wd_wa,wd_ra;'),
        ('reg [9:0] pp_wa,pp_ra;', 'reg [9:0] pp_wa,pp_ra,pd_wa,pd_ra;'),
        ('reg [8:0] pd_wa,pd_ra,img_wa', 'reg [8:0] img_wa'),
        ('knot_ram #(.DEPTH(256)) dw_weights_ram', 'knot_weight_bank dw_weights_ram'),
        ('knot_ram #(.DEPTH(512)) dw_params_ram', 'knot_ram #(.DEPTH(1024)) dw_params_ram'),
        ('reg [383:0] dw_window;', 'reg [639:0] dw_window;'),
        ('reg [1:0] drain_slot;', 'reg [2:0] drain_slot;'),
        ('n<8;n=n+1) lb_we', 'n<12;n=n+1) lb_we'),
        ('n<5;n=n+1) wt_we', 'n<10;n=n+1) wt_we'),
        ('wd_ra=(og*3+ky)*4+prefetch;', 'wd_ra=(og*5+ky)*7+prefetch;'),
        ('c[4][11:10]*2', 'c[4][12:10]*2'),
        ('lb_select=(c[2]+ky)&3;', 'sl=c[2][2:0]+ky;lb_select=sl>=6?sl-6:sl;'),
        ('q_out_tag[13:12]*2', 'q_out_tag[13:11]*2'),
        ('pc<=0;pos<=0;prefetch<=0;', 'pc<=0;pos<=0;pw_cooldown<=0;prefetch<=0;'),
        ('win0<=win1;win1<=dw_new;', 'win0<=win1;win1<=win2;win2<=win3;win3<=dw_new;'),
        ('dw_window<={dw_new,win1,win0};', 'dw_window<={dw_new,win3,win2,win1,win0};'),
        ('drain_slot<=c[8][1:0]', 'drain_slot<=c[8][2:0]'),
        ("{drain_target,drain_slot,2'b0,", "{drain_target,drain_slot,1'b0,"),
        ('if(bank_count==4)', 'if(bank_count==9)'),
        ('param[15]<=pp_rd;x<=0;ig<=0;quarter<=0;plane<=0;', 'param[15]<=pp_rd;x<=0;ig<=0;quarter<=0;plane<=0;pw_cooldown<=0;'),
        ('P_RUN:begin\n                pw_v', 'P_RUN:begin\n                if(pw_cooldown!=0) pw_cooldown<=pw_cooldown-1;\n                else begin\n                pw_v'),
        ('quarter==3', 'quarter==1'),
        ('ig<=0;x<=x+1;in_index', 'pw_cooldown<=pw_pixel_issues<pw_min_spacing?pw_min_spacing-pw_pixel_issues:0;\n                            ig<=0;x<=x+1;in_index'),
        ('end else plane<=plane+1;\n            end', 'end else plane<=plane+1;\n                end\n            end'),
        ('og+1==c[3]?16:7', 'og+1==c[3]?17:8'),
        ('(c[4][1]?(c[2][8:0]<<3):(c[2][8:0]<<2))', '(c[4][1]?(c[2][8:0]<<2):(c[2][8:0]<<1))'),
        ('if(prefetch==3)state<=D_WWAIT', 'if(prefetch==6)state<=D_WWAIT'),
        ("dw_weights[239:192]<=wd_rd[47:0];line_index<=$signed({1'b0,og})-(c[12][0]?$signed({6'b0,c[7][4:0]}):11'sd0);col<=0;dw_x<=0;stride_phase<=0;win0<=0;win1<=0;state<=D_RUN;", "dw_weights[399:384]<=wd_rd[15:0];line_index<=$signed({2'b0,og})-$signed({5'b0,c[7][5:0]})*$signed({9'b0,c[12][1:0]});col<=0;dw_x<=0;stride_phase<=0;win0<=0;win1<=0;win2<=0;win3<=0;state<=D_RUN;"),
        ("$signed({6'b0,c[7][4:0]})", "$signed({5'b0,c[7][5:0]})"),
        ('if(wait_count==5)', 'if(wait_count==6)'),
        ('out_index+c[7][4:0]', 'out_index+c[7][5:0]'),
    ]
    for before, after in changes:
        assert before in s, before
        s = s.replace(before, after)
    path.write_text(s, newline='\n')
    top = rtl / 'rm_cnn_top.sv'
    top.write_text(top.read_text().replace('53564b31', '53564831').replace('SVK1', 'SVH1'), newline='\n')
    (HERE/'source_baseline.json').write_text(json.dumps(sources,indent=2)+'\n')


if __name__ == '__main__':
    main()
