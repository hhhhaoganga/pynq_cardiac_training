#pragma once
#include <ap_axi_sdata.h>
#include <hls_stream.h>

using shape_axis_word = ap_axiu<32, 0, 0, 0>;

void shape_top(hls::stream<shape_axis_word> &input,
               hls::stream<shape_axis_word> &output);
