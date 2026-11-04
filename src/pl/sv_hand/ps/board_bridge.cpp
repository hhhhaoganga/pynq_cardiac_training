#include "hw.hpp"
#include <string>
#include <exception>
namespace { thread_local std::string error; }
extern "C" {
const char* board_error(){return error.c_str();}
void* board_alloc(unsigned bytes){try{return new hw::DmaBuf(bytes);}catch(const std::exception& e){error=e.what();return nullptr;}}
void board_free(void* p){delete static_cast<hw::DmaBuf*>(p);}
void* board_data(void* p){return static_cast<hw::DmaBuf*>(p)->data();}
unsigned board_phys(void* p){return static_cast<hw::DmaBuf*>(p)->phys();}
int board_sync(void* p,unsigned off,unsigned bytes,int invalidate){try{
    auto& b=*static_cast<hw::DmaBuf*>(p);
    if(off>b.size()||bytes>b.size()-off)throw hw::Error("DMA range outside allocation");
    if(invalidate)b.invalidate(off,bytes);else b.flush(off,bytes);return 0;
}catch(const std::exception& e){error=e.what();return -1;}}
int board_load(const char* path){try{
    hw::stage_firmware(path,"hand_sv_full_current.bin");
    hw::fpga_load("hand_sv_full_current.bin",false);hw::DfxSlot().release();return 0;
}catch(const std::exception& e){error=e.what();return -1;}}
void board_fclks(double* mhz){hw::read_fclks(mhz);}
}
