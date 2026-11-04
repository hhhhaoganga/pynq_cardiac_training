#include "hand_ps.hpp"
#include <exception>
#include <string>
namespace { thread_local std::string error; }
extern "C" {
const char* hand_error(){return error.c_str();}
void* hand_tail_create(const char* file){try{return new hand_ps::Tail(file);}catch(const std::exception& e){error=e.what();return nullptr;}}
void hand_tail_destroy(void* handle){delete static_cast<hand_ps::Tail*>(handle);}
int hand_tail_run(void* handle,const uint8_t* feature,double* outputs){
    if(!handle)return -1;
    try{static_cast<hand_ps::Tail*>(handle)->run(feature,outputs);return 0;}catch(const std::exception& e){error=e.what();return -1;}
}
}
