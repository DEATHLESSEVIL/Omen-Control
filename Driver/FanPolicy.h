#pragma once
// Portable validation shared by the kernel bridge and its boundary tests.
inline bool omenFanLimits(const uint8_t *data, unsigned size, uint8_t minimum[2], uint8_t maximum[2]) {
    if (!data || size != 128 || data[0] != 2) return false;
    minimum[0]=minimum[1]=255; maximum[0]=maximum[1]=0;
    unsigned rows=0;
    for(unsigned i=2;i+2<size;i+=3) {
        if(!data[i] && !data[i+1] && !data[i+2])break;
        if(data[i]<10 || data[i]>100 || data[i+1]<10 || data[i+1]>100)return false;
        for(unsigned fan=0;fan<2;++fan) {
            if(data[i+fan]<minimum[fan])minimum[fan]=data[i+fan];
            if(data[i+fan]>maximum[fan])maximum[fan]=data[i+fan];
        }
        ++rows;
    }
    return rows && minimum[0]<=maximum[0] && minimum[1]<=maximum[1];
}
inline bool omenManualTarget(uint8_t minimum, uint8_t maximum, uint64_t percent, uint8_t *result) {
    if(!result || minimum<10 || maximum>100 || minimum>maximum || percent>100)return false;
    if(percent==0) { *result=0; return true; } // Firmware automatic, never fan stop.
    uint64_t units=(maximum*percent+50)/100;
    if(units<minimum)units=minimum;
    *result=static_cast<uint8_t>(units); return true;
}
inline bool omenDecodeKey(const uint8_t *data, unsigned size, uint32_t *id, uint32_t *value) {
    if(!data || !id || !value || (size!=8 && size!=16))return false;
    unsigned offset=size==8?4:8;
    *id=static_cast<uint32_t>(data[0])|(static_cast<uint32_t>(data[1])<<8)|(static_cast<uint32_t>(data[2])<<16)|(static_cast<uint32_t>(data[3])<<24);
    *value=static_cast<uint32_t>(data[offset])|(static_cast<uint32_t>(data[offset+1])<<8)|(static_cast<uint32_t>(data[offset+2])<<16)|(static_cast<uint32_t>(data[offset+3])<<24);
    return true;
}
