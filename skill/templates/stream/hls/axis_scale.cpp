// AXI-Stream kernel: y = x * k + b. Fed by AXI DMA MM2S, drained by S2MM.
#include <ap_axi_sdata.h>
#include <hls_stream.h>

typedef ap_axiu<32, 0, 0, 0> axis_t;  // data + keep/strb/last

extern "C" void axis_scale(hls::stream<axis_t> &in_s, hls::stream<axis_t> &out_s,
                           int n, int k, int b) {
#pragma HLS INTERFACE mode=axis port=in_s
#pragma HLS INTERFACE mode=axis port=out_s
#pragma HLS INTERFACE mode=s_axilite port=n
#pragma HLS INTERFACE mode=s_axilite port=k
#pragma HLS INTERFACE mode=s_axilite port=b
#pragma HLS INTERFACE mode=s_axilite port=return
    for (int i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
        axis_t v = in_s.read();
        axis_t o;
        // unsigned math wraps mod 2^32 like the golden model (signed overflow is UB in C++)
        o.data = (unsigned)((unsigned)(int)v.data * (unsigned)k + (unsigned)b);
        o.keep = -1;
        o.strb = -1;
        // S2MM only completes on TLAST: drive it on the last beat ourselves rather than
        // forwarding v.last, so a mismatched n still terminates the DMA transfer.
        o.last = (i == n - 1);
        out_s.write(o);
    }
}
