#include <cstdint>
#include <cassert>
#include <cstdio>
#include <limits>
#include "FanPolicy.h"
int main() {
    uint8_t data[128]={2,0,20,25,30,50,60,45}, lo[2], hi[2], target=0;
    assert(omenFanLimits(data,128,lo,hi));
    assert(lo[0]==20 && hi[0]==50 && lo[1]==25 && hi[1]==60);
    assert(omenManualTarget(lo[0],hi[0],70,&target) && target==35);
    assert(omenManualTarget(lo[1],hi[1],70,&target) && target==42);
    assert(omenManualTarget(49,50,70,&target) && target==49);
    assert(omenManualTarget(20,50,100,&target) && target==50);
    assert(omenManualTarget(20,50,0,&target) && target==0);
    assert(omenManualTarget(20,50,1,&target) && target==20);
    assert(omenManualTarget(20,50,30,&target) && target==20);
    assert(omenManualTarget(20,50,69,&target) && target==35);
    for(uint64_t p=1;p<=100;++p) { assert(omenManualTarget(20,60,p,&target)); assert(target>=20 && target<=60); }
    assert(!omenManualTarget(20,50,101,&target));
    assert(!omenManualTarget(20,50,std::numeric_limits<uint64_t>::max(),&target));
    assert(!omenManualTarget(60,50,90,&target));
    assert(!omenFanLimits(data,127,lo,hi));
    data[0]=1; assert(!omenFanLimits(data,128,lo,hi));
    data[0]=2; data[3]=0; assert(!omenFanLimits(data,128,lo,hi));
    data[3]=25; data[5]=255; assert(!omenFanLimits(data,128,lo,hi));
    uint8_t empty[128]={2}; assert(!omenFanLimits(empty,128,lo,hi));
    uint32_t id=0, value=0;
    uint8_t key8[8]={0x1d,0,0,0,0xa5,0x21,0,0};
    assert(omenDecodeKey(key8,8,&id,&value) && id==0x1d && value==0x21a5);
    uint8_t key16[16]={0x1d,0,0,0,0xff,0xff,0xff,0xff,0xa5,0x21,0,0};
    assert(omenDecodeKey(key16,16,&id,&value) && id==0x1d && value==0x21a5);
    assert(!omenDecodeKey(key16,12,&id,&value));
    assert(!omenDecodeKey(nullptr,8,&id,&value));
    puts("Fan policy and HP key-event boundary tests passed.");
}
