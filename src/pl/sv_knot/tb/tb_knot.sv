`timescale 1ns/1ps
module tb_knot;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,start=0;
    reg [31:0] program_address;
    wire busy,done,fault;
    wire rcv,rcr,rv,rr,wcv,wcr,wv,wr;
    wire [31:0] ra,wa;
    wire [15:0] rn,wn;
    wire [63:0] rdata,wdata,cycles;
    wire check_valid;wire [7:0] check_block;
    wire [31:0] check_address,check_count;
    knot_core dut(clk,reset,start,program_address,busy,done,fault,
        rcv,rcr,ra,rn,rv,rr,rdata,wcv,wcr,wa,wn,wv,wr,wdata,
        check_valid,check_block,check_address,check_count,cycles);
    reg [63:0] mem[0:399999],golden[0:208799];
    reg [31:0] rptr,wptr;
    reg [16:0] rleft=0,wleft=0;
    integer stall=0,seed=1,checked=0,total_errors=0;
    integer state_cycles[0:63];
    initial for(integer j=0;j<64;j=j+1)state_cycles[j]=0;
    reg [31:0] random_state=32'h12345678;
    wire allow_r=!stall||random_state[2:0]!=0;
    wire allow_w=!stall||random_state[6:4]!=0;
    assign rcr=rleft==0;
    assign wcr=wleft==0;
    // Once valid is asserted, data remains held through downstream backpressure.
    reg read_pending=0;
    assign rv=(rleft!=0)&&read_pending;
    assign rdata=mem[rptr];
    assign wr=(wleft!=0)&&allow_w;
    always @(posedge clk) begin
        random_state<={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        if(rcv&&rcr)begin rptr<=ra;rleft<=rn;read_pending<=0;
            if(ra+rn>400000||rn==0)$fatal(1,"Invalid read command");end
        else if(rv&&rr)begin rptr<=rptr+1;rleft<=rleft-1;read_pending<=allow_r;end
        else if(rleft!=0&&!read_pending&&allow_r)read_pending<=1;
        if(wcv&&wcr)begin wptr<=wa;wleft<=wn;
            if(wa+wn>400000||wn==0)$fatal(1,"Invalid write command");end
        else if(wv&&wr)begin mem[wptr]<=wdata;wptr<=wptr+1;wleft<=wleft-1;end
        if(!reset&&busy)state_cycles[dut.state]=state_cycles[dut.state]+1;
        if(check_valid)begin
            total_errors=0;
            for(integer j=0;j<check_count;j=j+1) begin
                if(mem[check_address+j]!==golden[check_address+j])begin
                    if(total_errors<8)$display("MISMATCH block=%0d beat=%0d actual=%016x golden=%016x",check_block,j,mem[check_address+j],golden[check_address+j]);
                    total_errors=total_errors+1;
                end
            end
            if(total_errors)$fatal(1,"BLOCK_FAILED block=%0d errors=%0d",check_block,total_errors);
            checked=checked+1;$display("BLOCK_PASS %0d cycles=%0d",check_block,cycles);
        end
        if(done)begin
            if(fault||checked!=22)$fatal(1,"Incomplete run checked=%0d fault=%b",checked,fault);
            for(integer j=0;j<64;j=j+1)if(state_cycles[j])$display("STATE_CYCLES %0d %0d",j,state_cycles[j]);
            $display("SV_KNOT_FULL_PASS blocks=%0d cycles=%0d stall=%0d",checked,cycles,stall);$finish;
        end
        if(cycles>20000000)$fatal(1,"Timeout state=%0d pc=%0d",dut.state,dut.pc);
    end
    initial begin
        if(!$value$plusargs("PROGRAM=%d",program_address))$fatal(1,"PROGRAM required");
        if($value$plusargs("STALL=%d",stall))begin end
        $readmemh("fixture/memory.hex",mem);
        $readmemh("fixture/golden.hex",golden);
        repeat(10)@(negedge clk);reset=0;@(negedge clk);start=1;@(negedge clk);start=0;
    end
endmodule
