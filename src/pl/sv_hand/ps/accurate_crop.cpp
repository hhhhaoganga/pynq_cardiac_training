// Axis-aligned original ROI crop, preserving the OpenCV 5 accurate float
// coordinate/interpolation order used by the accepted video reference.
// Float multiply-adds are rounded once using double intermediates on Cortex-A9.
#include <cstdint>
#include <cmath>
#include <algorithm>
#include <cstring>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
namespace {
float fm(float a,float b,float c){return float(double(a)*double(b)+double(c));}
}
extern "C" int hand_crop(const uint8_t* bgr,int w,int h,double cx,double cy,double side,uint8_t* rgbx){
    if(!bgr||!rgbx||w<=0||h<=0||!std::isfinite(cx)||!std::isfinite(cy)||!std::isfinite(side)||side<1||side>8192)return -1;
    const double s=224.0/side;
    const double a=float(s),tx=float(112-s*cx),ty=float(112-s*cy);
    const double inv=a*(1.0/(a*a));
    const float m=float(inv),mx=float(-inv*tx),my=float(-inv*ty);
    int ix[224],iy[224];float fx[224],fy[224];
    for(int x=0;x<224;x++){const float v=fm(m,float(x),mx);ix[x]=int(std::floor(v));fx[x]=v-ix[x];}
    for(int y=0;y<224;y++){const float product=float(y)*m;const float v=product+my;iy[y]=int(std::floor(v));fy[y]=v-iy[y];}
    auto scalar=[&](int y,int x){
        const int xx=ix[x],yy=iy[y];uint8_t* dst=rgbx+(y*224+x)*4;
        for(int c=0;c<3;c++){
            const auto pixel=[&](int dx,int dy)->float {const int X=xx+dx,Y=yy+dy;return X>=0&&X<w&&Y>=0&&Y<h?bgr[(Y*w+X)*3+2-c]:0;};
            const float a0=pixel(0,0),b0=pixel(1,0),c0=pixel(0,1),d0=pixel(1,1);
            // ARMv7 has no fused float instruction. Away from a half-integer,
            // ordinary float arithmetic rounds to the same uint8; recompute
            // the tiny ambiguous interval with the exact reference ordering.
            const float u=a0+fx[x]*(b0-a0),v=c0+fx[x]*(d0-c0);
            float value=u+fy[y]*(v-u);
            const float near_half=value-float(int(value));
            if(near_half>0.4998f&&near_half<0.5002f){
                const float eu=fm(fx[x],b0-a0,a0),ev=fm(fx[x],d0-c0,c0);
                value=fm(fy[y],ev-eu,eu);
            }
            // Value is nonnegative; preserve nearest-even without a per-pixel
            // libm lrintf call on ARMv7.
            const int integer=int(value);const float fraction=value-integer;
            dst[c]=uint8_t(integer+(fraction>0.5f||(fraction==0.5f&&(integer&1))));
        }
        dst[3]=0;
    };
    for(int y=0;y<224;y++){
        if(iy[y]<-1||iy[y]>=h){std::memset(rgbx+y*224*4,0,224*4);continue;}
        int x=0;
#if defined(__ARM_NEON)
        for(;x<=220;){
            const int yy=iy[y];
            if(ix[x]>=w){std::memset(rgbx+(y*224+x)*4,0,(224-x)*4);x=224;break;}
            if(ix[x]<-1){std::memset(rgbx+(y*224+x)*4,0,4);x++;continue;}
            if(yy<0||yy+1>=h||ix[x]<0||ix[x+3]+1>=w-1){scalar(y,x++);continue;}
            uint32_t aa[4],bb[4],cc[4],dd[4];
            for(int j=0;j<4;j++){
                const auto* p=bgr+(yy*w+ix[x+j])*3;
                std::memcpy(aa+j,p,4);std::memcpy(bb+j,p+3,4);
                std::memcpy(cc+j,p+w*3,4);std::memcpy(dd+j,p+w*3+3,4);
            }
            const uint32x4_t av=vld1q_u32(aa),bv=vld1q_u32(bb),cv=vld1q_u32(cc),dv=vld1q_u32(dd),mask=vdupq_n_u32(255);
            const float32x4_t vx=vld1q_f32(fx+x),vy=vdupq_n_f32(fy[y]);
            uint32x4_t packed=vdupq_n_u32(0),ambiguous=vdupq_n_u32(0);
            for(int c=0;c<3;c++){
                const int32x4_t sh=vdupq_n_s32(-(2-c)*8);
                const float32x4_t a0=vcvtq_f32_u32(vandq_u32(vshlq_u32(av,sh),mask));
                const float32x4_t b0=vcvtq_f32_u32(vandq_u32(vshlq_u32(bv,sh),mask));
                const float32x4_t c0=vcvtq_f32_u32(vandq_u32(vshlq_u32(cv,sh),mask));
                const float32x4_t d0=vcvtq_f32_u32(vandq_u32(vshlq_u32(dv,sh),mask));
                const float32x4_t u=vmlaq_f32(a0,vx,vsubq_f32(b0,a0)),v=vmlaq_f32(c0,vx,vsubq_f32(d0,c0));
                const float32x4_t value=vmlaq_f32(u,vy,vsubq_f32(v,u));
                const float32x4_t frac=vsubq_f32(value,vcvtq_f32_u32(vcvtq_u32_f32(value)));
                ambiguous=vorrq_u32(ambiguous,vandq_u32(vcgtq_f32(frac,vdupq_n_f32(.4998f)),vcltq_f32(frac,vdupq_n_f32(.5002f))));
                const uint32x4_t q=vcvtq_u32_f32(vaddq_f32(value,vdupq_n_f32(.5f)));
                packed=vorrq_u32(packed,vshlq_u32(q,vdupq_n_s32(c*8)));
            }
            vst1q_u32(reinterpret_cast<uint32_t*>(rgbx+(y*224+x)*4),packed);
            uint32_t flags[4];vst1q_u32(flags,ambiguous);
            for(int j=0;j<4;j++)if(flags[j])scalar(y,x+j);
            x+=4;
        }
#endif
        for(;x<224;x++)scalar(y,x);
    }
    return 0;
}
