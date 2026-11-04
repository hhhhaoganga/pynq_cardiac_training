// Vector add: c[i] = a[i] + b[i] (int32 wraparound), m_axi data + s_axilite control.
extern "C" void vadd(const int *a, const int *b, int *c, int n) {
#pragma HLS INTERFACE m_axi port=a bundle=gmem0 offset=slave depth=1024 max_read_burst_length=64
#pragma HLS INTERFACE m_axi port=b bundle=gmem1 offset=slave depth=1024 max_read_burst_length=64
#pragma HLS INTERFACE m_axi port=c bundle=gmem2 offset=slave depth=1024 max_write_burst_length=64
#pragma HLS INTERFACE s_axilite port=n
#pragma HLS INTERFACE s_axilite port=return
    for (int i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=1024 max=1024
        c[i] = (int)((unsigned)a[i] + (unsigned)b[i]);
    }
}
