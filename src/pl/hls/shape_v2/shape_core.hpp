#pragma once
#include <cstdint>
#include <cstddef>
namespace shape {
static const int INPUT_BYTES=2*224*224;
inline int32_t mac(int32_t sum,int8_t a,int8_t b) {
    return sum + int32_t(a)*int32_t(b);
}
// Contract products fit 45 signed bits; avoid FP and negative signed shifts.
inline int8_t requantize(int32_t acc,int64_t multiplier,unsigned shift,bool relu) {
    const int64_t product=int64_t(acc)*multiplier;
    const bool negative=product<0;
    const uint64_t magnitude=negative?uint64_t(-product):uint64_t(product);
    uint64_t rounded=magnitude>>shift;
    const uint64_t remainder=magnitude&((uint64_t(1)<<shift)-1);
    const uint64_t half=uint64_t(1)<<(shift-1);
    if(remainder>half || (remainder==half && (rounded&1))) ++rounded;
    if(relu && negative) return 0;
    if(rounded>127) return negative?int8_t(-127):int8_t(127);
    return int8_t(negative?-int64_t(rounded):int64_t(rounded));
}
void infer(const int8_t input[INPUT_BYTES],int8_t output[16]);
}
