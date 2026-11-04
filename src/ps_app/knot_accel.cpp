#include "knot_accel.hpp"
#include <cstring>
#include <fstream>
#include <cstdio>
#include <stdexcept>

namespace accel {
Knot::Knot(const std::string &directory):dir_(directory),regs_(hw::RP_CTRL_BASE,0x1000) {
    std::ifstream meta(dir_+"/metadata.txt");
    std::string magic; int iw=0,ih=0,ow=0,oh=0,padded=0,valid=0;
    meta>>magic>>bytes_>>program_>>input_>>iw>>ih>>output_>>ow>>oh>>padded>>valid;
    if(!meta || magic!="SVK1" || iw!=320 || ih!=256 || ow!=40 || oh!=32 || padded!=16 || valid!=7 ||
       bytes_>16*1024*1024 || input_+320*256*4>bytes_ || output_+40*32*64>bytes_ || uint64_t(program_)*8>=bytes_)
        throw hw::Error("Invalid 256x320 SVK1 package metadata");
    memory_=std::make_unique<hw::DmaBuf>(bytes_);
    std::ifstream image(dir_+"/memory.bin",std::ios::binary);
    image.read(reinterpret_cast<char*>(memory_->data()),bytes_);
    if(!image || image.peek()!=std::char_traits<char>::eof())throw hw::Error("SVK1 memory image size mismatch");
    std::ifstream scale(dir_+"/head_dequant.bin",std::ios::binary);
    scale.read(reinterpret_cast<char*>(dequant_),sizeof(dequant_));
    if(!scale)throw hw::Error("Missing SVK1 head dequantization scales");
    memory_->flush();
}
void Knot::initialize() {
    if(regs_.rd(0x3c)!=0x53564b31)throw hw::Error("Expected SVK1 knot core; wrong bitstream");
    if((regs_.rd(0)&4)==0)throw hw::Error("SVK1 core is not idle");
    regs_.wr(0x10,memory_->phys()); regs_.wr(0x18,program_);
    std::printf("knot-sv: signature SVK1, input 320x256, DDR 0x%08x, program %u\n",memory_->phys(),program_);
}
KnotStats Knot::execute() {
    if(regs_.rd(0x3c)!=0x53564b31 || (regs_.rd(0)&4)==0)throw hw::Error("SVK1 not ready");
    regs_.wr(0x10,memory_->phys());regs_.wr(0x18,program_);
    regs_.wr(0x0c,1);
    const uint64_t start=hw::now_us();
    regs_.wr(0,1);
    for(;;) {
        const auto status=regs_.rd(0);
        if(status&16)throw hw::Error("SVK1 AXI/core fault");
        if(status&2)break;
        if(hw::now_us()-start>2000000)throw hw::Error("SVK1 inference timeout");
        hw::sleep_us(50);
    }
    KnotStats result;
    result.kernel_ms=(hw::now_us()-start)/1000.0;
    result.cycles=regs_.rd64(0x20);
    return result;
}
KnotStats Knot::run(const std::vector<uint8_t> &rgb,std::vector<float> &head) {
    if(rgb.size()!=320*256*3)throw hw::Error("SVK1 expects 320x256 RGB");
    const auto start=hw::now_us();
    auto *input=memory_->data()+input_;
    for(size_t p=0;p<320*256;p++) {
        input[4*p]=rgb[3*p];input[4*p+1]=rgb[3*p+1];input[4*p+2]=rgb[3*p+2];input[4*p+3]=0;
    }
    memory_->flush(input_,320*256*4);
    auto result=execute();
    memory_->invalidate(output_,40*32*64);
    head.resize(40*32*7);
    const auto *raw=reinterpret_cast<const int32_t*>(memory_->data()+output_);
    for(size_t p=0;p<40*32;p++)for(size_t c=0;c<7;c++)head[p*7+c]=raw[p*16+c]*dequant_[c];
    result.service_ms=(hw::now_us()-start)/1000.0;
    return result;
}
void Knot::verify_golden() {
    std::ifstream file(dir_+"/golden.bin",std::ios::binary);
    std::vector<uint8_t> golden((std::istreambuf_iterator<char>(file)),{});
    std::ifstream checks(dir_+"/checks.txt");
    std::vector<std::pair<size_t,size_t>> spans;
    size_t offset,length;
    while(checks>>offset>>length) {
        if(offset+length>bytes_ || offset+length>golden.size())throw hw::Error("SVK1 golden bounds");
        spans.emplace_back(offset,length);
        std::memset(memory_->data()+offset,0xa5,length);
    }
    if(spans.size()!=22)throw hw::Error("Expected 22 SVK1 golden blocks");
    memory_->flush();
    const auto result=execute();
    memory_->invalidate();
    for(size_t b=0;b<spans.size();b++) {
        auto [a,n]=spans[b];
        for(size_t j=0;j<n;j++)if(memory_->data()[a+j]!=golden[a+j])
            throw hw::Error("SVK1 golden mismatch block "+std::to_string(b)+" byte "+std::to_string(j));
    }
    std::printf("KNOT_SV_GOLDEN_PASS blocks=22 cycles=%llu kernel_ms=%.3f\n",
                (unsigned long long)result.cycles,result.kernel_ms);
}
}
