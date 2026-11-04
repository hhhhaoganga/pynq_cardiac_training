#include "shape_top.hpp"
#include "shape_core.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<int8_t> read_case(const std::string &name,size_t n,size_t offset) {
    const char *fixture=std::getenv("SHAPE_HLS_FIXTURE");
    if(!fixture)throw std::runtime_error("SHAPE_HLS_FIXTURE is not set");
    std::ifstream f(std::string(fixture)+"/"+name,std::ios::binary);
    if(!f)throw std::runtime_error("cannot open "+name);
    f.seekg(offset);
    std::vector<int8_t> result(n);
    if(!f.read(reinterpret_cast<char*>(result.data()),n))throw std::runtime_error("short "+name);
    return result;
}

int main() {
    try {
        std::vector<int> ids;
#ifdef SHAPE_COSIM
        ids={13,73,130};
#else
        for(int i=0;i<150;i++)ids.push_back(i);
#endif
        for(int id:ids) {
            const auto bytes=read_case("inputs.bin",shape::INPUT_BYTES,size_t(id)*shape::INPUT_BYTES);
            const auto expected=read_case("expected.bin",16,id*16);
            hls::stream<shape_axis_word> input("input"), output("output");
            for(int i=0;i<shape::INPUT_BYTES/4;i++) {
                shape_axis_word word;
                word.data=0;
                for(int lane=0;lane<4;lane++)word.data.range(lane*8+7,lane*8)=uint8_t(bytes[i*4+lane]);
                word.keep=15;word.strb=15;word.last=(i==shape::INPUT_BYTES/4-1);
                input.write(word);
            }
            shape_top(input,output);
            if(!input.empty())throw std::runtime_error("input words not consumed");
            for(int i=0;i<4;i++) {
                if(output.empty())throw std::runtime_error("missing output word");
                const shape_axis_word word=output.read();
                if(word.keep!=15 || word.strb!=15 || bool(word.last)!=(i==3))throw std::runtime_error("bad keep/strb/last");
                for(int lane=0;lane<4;lane++) {
                    const int8_t actual=int8_t(word.data.range(lane*8+7,lane*8).to_uint());
                    if(actual!=expected[i*4+lane])throw std::runtime_error("coefficient mismatch case="+std::to_string(id)+" index="+std::to_string(i*4+lane));
                }
            }
            if(!output.empty())throw std::runtime_error("extra output words");
            std::cout<<"PASS case="<<id<<" words_in=25088 words_out=4"<<std::endl;
        }
        std::cout<<"PASS top cases="<<ids.size()<<std::endl;
        return 0;
    } catch(const std::exception &e) {
        std::cerr<<"FAIL "<<e.what()<<std::endl;
        return 1;
    }
}
