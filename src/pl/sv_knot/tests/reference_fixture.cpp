// Exercise the already validated HLS C integer reference on a different input.
// This is a test oracle only; none of this C++ is synthesized into the SV design.
#include "cnn_engine.hpp"
#include <cstdint>
#include <fstream>
#include <iterator>
#include <vector>
#include <string>
#include <iostream>
#include <cstring>
int main(int argc,char**argv){
    if(argc!=3)return 2;
    std::ifstream f(std::string(argv[1])+"/mem_init.bin",std::ios::binary);
    if(!f)return 2;
    std::vector<unsigned char> bytes{std::istreambuf_iterator<char>(f),{}};
    auto desc=[&](int i){int32_t v;std::memcpy(&v,bytes.data()+4*i,4);return v;};
    const int h=desc(5),w=desc(6),base=desc(40);
    if(h!=256||w!=320||base<0||base+4*h*w>int(bytes.size()))return 2;
    uint32_t state=0x42765193;
    for(int i=0;i<h*w;i++)for(int c=0;c<4;c++){
        state^=state<<13;state^=state>>17;state^=state<<5;
        bytes[base+4*i+c]=c==3?0:static_cast<unsigned char>(state);
    }
    std::ofstream input(std::string(argv[2])+"/mem_init.bin",std::ios::binary);
    input.write(reinterpret_cast<char*>(bytes.data()),bytes.size());input.close();
    std::vector<beat_t> mem(400000);
    for(size_t i=0;i<bytes.size();i++)mem[i/8].range(8*(i%8)+7,8*(i%8))=bytes[i];
    cnn_top(mem.data(),0,22);
    for(size_t i=0;i<bytes.size();i++)bytes[i]=mem[i/8].range(8*(i%8)+7,8*(i%8));
    std::ofstream golden(std::string(argv[2])+"/golden.bin",std::ios::binary);
    golden.write(reinterpret_cast<char*>(bytes.data()),bytes.size());
    std::cout<<"RANDOM_REFERENCE_COMPLETE "<<bytes.size()<<" bytes\n";
}
