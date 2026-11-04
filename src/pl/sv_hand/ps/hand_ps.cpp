#include "hand_ps.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace hand_ps {
namespace {
template<class T> T read(std::ifstream& f) {
    T value{}; f.read(reinterpret_cast<char*>(&value), sizeof value);
    if(!f)throw std::runtime_error("Truncated hand tail package");
    return value;
}
int32_t dot(const int16_t* a,const int16_t* b,int n) {
    int i=0;int32_t result=0;
#if defined(__ARM_NEON)
    int32x4_t s0=vdupq_n_s32(0),s1=vdupq_n_s32(0);
    for(;i+8<=n;i+=8) {
        s0=vmlal_s16(s0,vld1_s16(a+i),vld1_s16(b+i));
        s1=vmlal_s16(s1,vld1_s16(a+i+4),vld1_s16(b+i+4));
    }
    const int32x4_t s=vaddq_s32(s0,s1);
    result=vgetq_lane_s32(s,0)+vgetq_lane_s32(s,1)+vgetq_lane_s32(s,2)+vgetq_lane_s32(s,3);
#endif
    for(;i<n;i++)result+=int32_t(a[i])*b[i];
    return result;
}
}

Tail::Tail(const std::string& file) {
    std::ifstream f(file,std::ios::binary);
    if(read<uint32_t>(f)!=0x314c5448)throw std::runtime_error("Expected HTL1 tail");
    pixels_=read<int32_t>(f);channels_=read<int32_t>(f);signed_=read<int32_t>(f);
    mult_=read<int32_t>(f);shift_=read<int32_t>(f);lo_=read<int32_t>(f);hi_=read<int32_t>(f);
    const int heads=read<int32_t>(f);
    if(pixels_!=49||channels_!=672||(signed_!=0&&signed_!=1)||heads!=4||
       mult_<=0||shift_<1||shift_>55||lo_<-127||hi_>255||lo_>hi_||
       int64_t(pixels_)*255*mult_>std::numeric_limits<int64_t>::max()-(int64_t(1)<<(shift_-1)))
        throw std::runtime_error("Unexpected original landmark tail dimensions or quantization");
    for(int h=0;h<heads;h++) {
        Head head;head.outputs=read<int32_t>(f);
        if(head.outputs!=1&&head.outputs!=63)throw std::runtime_error("Invalid hand head");
        head.weights.resize(size_t(head.outputs)*channels_);
        head.bias.resize(head.outputs);head.scale.resize(head.outputs);
        for(auto& w:head.weights)w=read<int8_t>(f);
        for(auto& b:head.bias)b=read<int32_t>(f);
        for(auto& s:head.scale){s=read<float>(f);if(!std::isfinite(s)||s<=0)throw std::runtime_error("Invalid dequant scale");}
        for(int c=0;c<head.outputs;c++) {
            int64_t bound=std::abs(int64_t(head.bias[c]));
            for(int i=0;i<channels_;i++)bound+=255*std::abs(int(head.weights[c*channels_+i]));
            if(bound>INT32_MAX)throw std::runtime_error("FC accumulator may overflow");
        }
        output_count_+=head.outputs;heads_.push_back(std::move(head));
    }
    if(output_count_!=128||f.peek()!=std::char_traits<char>::eof())throw std::runtime_error("Invalid tail package size");
    sums_.resize(channels_);mean_.resize(channels_);
}

void Tail::run(const uint8_t* feature,double* outputs) {
    if(!feature||!outputs)throw std::invalid_argument("Null tail buffer");
    std::fill(sums_.begin(),sums_.end(),0);
    // Contiguous rows reduce cache misses compared with channel-major striding.
    for(int p=0;p<pixels_;p++)for(int c=0;c<channels_;c++) {
        const uint8_t v=feature[size_t(p)*channels_+c];
        sums_[c]+=signed_&&v>=128?int(v)-256:int(v);
    }
    for(int c=0;c<channels_;c++) {
        const int64_t rounded=int64_t(sums_[c])*mult_+(int64_t(1)<<(shift_-1));
        const int64_t divisor=int64_t(1)<<shift_;
        const int64_t q=rounded>=0?rounded/divisor:-((-rounded+divisor-1)/divisor);
        mean_[c]=int16_t(std::max(int64_t(lo_),std::min(int64_t(hi_),q)));
    }
    size_t offset=0;
    for(const auto& h:heads_) {
        for(int o=0;o<h.outputs;o++) {
            const int32_t value=h.bias[o]+dot(mean_.data(),h.weights.data()+size_t(o)*channels_,channels_);
            outputs[offset++]=double(value)*double(h.scale[o]);
        }
    }
}
}
