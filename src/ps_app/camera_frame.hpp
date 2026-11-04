#pragma once
#include "hw.hpp"
#include <cstdint>
#include <memory>
#include <vector>

namespace app {
struct FrameStorage {
    explicit FrameStorage(size_t bytes, unsigned id): buffer(bytes), slot(id) {}
    hw::DmaBuf buffer;
    unsigned slot;
};
struct FramePool {
    FramePool(int w,int h): width(w),height(h) {
        for(unsigned i=0;i<4;++i)slots.push_back(std::make_shared<FrameStorage>(size_t(w)*h*4,i));
    }
    const int width,height;
    std::vector<std::shared_ptr<FrameStorage>> slots;
};
// Immutable after publication. Holding this snapshot keeps its slot out of
// the producer's free list; the pool itself never owns a snapshot.
struct CameraFrame {
    std::shared_ptr<FramePool> pool;
    std::shared_ptr<FrameStorage> storage;
    uint64_t sequence=0,captured_us=0,decoded_us=0;
    bool capture_timestamp_from_driver=false;
    const uint32_t* data() const {return reinterpret_cast<const uint32_t*>(storage->buffer.data());}
    int width() const {return pool->width;}
    int height() const {return pool->height;}
};
}
