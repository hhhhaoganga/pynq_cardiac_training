`timescale 1ns/1ps
module camus_concat_job_rom_tb;
    logic [1:0] stage_index;
    logic valid;
    logic [8:0] low_width,low_height,tile_low_rows;
    logic [5:0] project_channels,skip_channels;
    logic signed [31:0] project_multiplier,skip_multiplier;
    logic signed [6:0] project_shift,skip_shift;
    camus_concat_job_rom dut(.*);
    initial begin
        stage_index=0; #1;
        if(!valid||low_width!=32||low_height!=32||project_channels!=16
                ||skip_channels!=16||tile_low_rows!=16
                ||project_multiplier!=548571000||project_shift!=29
                ||skip_multiplier!=813115001||skip_shift!=30) $fatal(1,"stage0");
        stage_index=1; #1;
        if(!valid||low_width!=64||low_height!=64||project_channels!=8
                ||skip_channels!=8||tile_low_rows!=16
                ||project_multiplier!=548148269||project_shift!=29
                ||skip_multiplier!=1027618255||skip_shift!=30) $fatal(1,"stage1");
        stage_index=2; #1;
        if(!valid||low_width!=128||low_height!=128||project_channels!=4
                ||skip_channels!=4||tile_low_rows!=8
                ||project_multiplier!=1038540936||project_shift!=30
                ||skip_multiplier!=547162870||skip_shift!=29) $fatal(1,"stage2");
        stage_index=3; #1; if(valid) $fatal(1,"invalid stage");
        $display("PASS camus_concat_job_rom stages=3");
        $finish;
    end
endmodule
