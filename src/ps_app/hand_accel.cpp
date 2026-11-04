#include "hand_accel.hpp"
#include <cstdio>
#include "hw.hpp"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
namespace accel {
namespace {
void transfer(int fd,void* p,size_t n,bool send_data) {
    auto* b=static_cast<uint8_t*>(p);
    while(n){ssize_t k=send_data ? ::send(fd,b,n,MSG_NOSIGNAL) : ::recv(fd,b,n,0);
        if(k<0&&errno==EINTR)continue;
        if(k<=0)throw hw::Error("Hand backend disconnected/timeout");b+=k;n-=size_t(k);}
}
template<class T>T get(const uint8_t* b,size_t o){T v;std::memcpy(&v,b+o,sizeof v);return v;}
}
Hand::~Hand(){
    if(fd_>=0)::close(fd_);
    if(in_flight_){
        // Deliberately pin one faulted slot until process exit. A lost backend
        // ACK cannot prove that hardware has stopped reading this allocation.
        static auto* quarantine=new std::vector<std::shared_ptr<const app::CameraFrame>>;
        quarantine->push_back(std::move(in_flight_));
    }
}
// Also drains a lag-mode backend: the reset waits for every queued PL job.
void Hand::initialize(){request(nullptr,0,0,0,true);carried_.reset();}
HandReply Hand::run(const std::vector<uint32_t>& b,int w,int h,uint64_t stamp){
    if(w!=640||h!=480||b.size()!=size_t(w)*h)throw hw::Error("Hand PL camera requires 640x480 XRGB");
    return request(reinterpret_cast<const uint8_t*>(b.data()),w,h,stamp,false);
}
HandReply Hand::request(const uint8_t* pixels,int w,int h,uint64_t stamp,bool reset){
    if(fd_<0){
        fd_=::socket(AF_UNIX,SOCK_STREAM,0);if(fd_<0)throw hw::Error("Hand socket allocation failed");
        sockaddr_un a{};a.sun_family=AF_UNIX;
        if(socket_path_.size()>=sizeof a.sun_path){::close(fd_);fd_=-1;throw hw::Error("Hand socket path too long");}
        std::strcpy(a.sun_path,socket_path_.c_str());
        if(::connect(fd_,reinterpret_cast<sockaddr*>(&a),sizeof a)){::close(fd_);fd_=-1;throw hw::Error("Hand PL service unavailable");}
        timeval t{3,0};::setsockopt(fd_,SOL_SOCKET,SO_RCVTIMEO,&t,sizeof t);::setsockopt(fd_,SOL_SOCKET,SO_SNDTIMEO,&t,sizeof t);
    }
    try{
        uint8_t header[24]{};uint32_t values[4]={0x31485356,unsigned(w),unsigned(h),unsigned(reset)};
        std::memcpy(header,values,16);double seconds=stamp/1e6;std::memcpy(header+16,&seconds,8);
        transfer(fd_,header,sizeof header,true);
        if(w)transfer(fd_,const_cast<uint8_t*>(pixels),size_t(w)*h*4,true);
        return receive_reply();
    }catch(...){::close(fd_);fd_=-1;throw;}
}
HandReply Hand::receive_reply(){
        uint32_t n=0;transfer(fd_,&n,4,false);if(n<48||n>1024)throw hw::Error("Invalid hand reply length");
        std::vector<uint8_t> b(n);transfer(fd_,b.data(),n,false);
        if(get<uint32_t>(b.data(),0))throw hw::Error(std::string(b.begin()+48,b.end()));
        const auto count=get<uint32_t>(b.data(),4);const bool lagged=get<uint32_t>(b.data(),12)==1;
        if(count>2||n!=48+count*188+(lagged?8:0))throw hw::Error("Invalid hand observation count");
        HandReply r;r.recovery=get<uint32_t>(b.data(),8);r.lagged=lagged;if(lagged)r.frame_seq=get<uint64_t>(b.data(),48+count*188);r.detection_ms=get<double>(b.data(),16);
        r.landmark_ms=get<double>(b.data(),24);r.kernel_ms=get<double>(b.data(),32);r.cycles=get<uint64_t>(b.data(),40);
        r.hands.resize(count);static_assert(sizeof(HandObservation)==188,"hand protocol packing");
        if(count)std::memcpy(r.hands.data(),b.data()+48,count*188);return r;
}
void Hand::register_pool(const std::shared_ptr<app::FramePool>& pool){
    if(registered_pool_==pool)return;
    if(pool->width!=640||pool->height!=480||pool->slots.size()!=4)throw hw::Error("Shared camera pool contract");
    uint32_t header[6]={0x314c5048,2,4,640,480,640*480*4};transfer(fd_,header,sizeof header,true);
    for(unsigned slot=0;slot<4;++slot){
        int exported=pool->slots[slot]->buffer.export_fd();
        alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};iovec io{&slot,sizeof slot};msghdr msg{};
        msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control;msg.msg_controllen=sizeof control;
        cmsghdr* c=CMSG_FIRSTHDR(&msg);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN(sizeof(int));
        std::memcpy(CMSG_DATA(c),&exported,sizeof exported);
        ssize_t count;do{count=::sendmsg(fd_,&msg,MSG_NOSIGNAL);}while(count<0&&errno==EINTR);
        if(count!=sizeof slot)throw hw::Error("Camera DMA descriptor registration failed");
    }
    uint32_t ack=1;transfer(fd_,&ack,sizeof ack,false);if(ack)throw hw::Error("Shared camera pool rejected");
    registered_pool_=pool;
}
HandReply Hand::run(std::shared_ptr<const app::CameraFrame> frame){
    if(in_flight_)throw hw::Error("Previous shared DMA frame fault: reconfigure before reuse");
    if(!frame||!frame->sequence)throw hw::Error("Empty camera frame");
    if(fd_<0){registered_pool_.reset();initialize();}
    try{
        register_pool(frame->pool);in_flight_=frame;
        // v2: both camera producer and crop consumer are CPUs. The socket
        // handoff publishes an immutable coherent mapping. PL reads only the
        // separately flushed 224x224 cropped input, never this full frame.
        const double flush_ms=0;
        uint8_t header[32]{};uint32_t words[4]={0x32485356,640,480,frame->storage->slot};
        std::memcpy(header,words,16);const double stamp=frame->captured_us/1e6;
        std::memcpy(header+16,&stamp,8);std::memcpy(header+24,&frame->sequence,8);
        const auto start=hw::now_us();transfer(fd_,header,sizeof header,true);
        auto reply=receive_reply();reply.flush_ms=flush_ms;reply.ipc_wall_ms=(hw::now_us()-start)/1000.0;
        if(reply.lagged){
            // Result belongs to carried_ (or nothing on the first frame); keep this one pinned.
            // The backend always keeps exactly this request's frame, so pinning it is correct
            // either way; an unexpected sequence only drops this one result.
            if(reply.frame_seq&&(!carried_||carried_->sequence!=reply.frame_seq)){
                std::printf("hand: lagged reply seq %llu, expected %llu; result dropped\n",(unsigned long long)reply.frame_seq,
                    (unsigned long long)(carried_?carried_->sequence:0));std::fflush(stdout);
                reply.frame_seq=0;reply.hands.clear();
            }
            reply.captured_us=reply.frame_seq?carried_->captured_us:0;carried_=std::move(in_flight_);
        }else{reply.frame_seq=frame->sequence;reply.captured_us=frame->captured_us;}
        in_flight_.reset();return reply;
    }catch(...){if(fd_>=0)::close(fd_);fd_=-1;throw;}
}

}
