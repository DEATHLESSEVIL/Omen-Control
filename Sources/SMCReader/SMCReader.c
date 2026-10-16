#include "SMCReader.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct { uint32_t key; Version version; PLimit limit; KeyInfo info; uint8_t result, status, command; uint32_t data32; uint8_t bytes[32]; } Packet;
_Static_assert(sizeof(Packet)==80, "AppleSMC ABI must be 80 bytes");
static uint32_t fourcc(const char *s) { return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3]; }
static int call(io_connect_t c, Packet *in, Packet *out) { size_t n=sizeof(*out); memset(out,0,n); kern_return_t r=IOConnectCallStructMethod(c,2,in,sizeof(*in),out,&n); return r==KERN_SUCCESS && n==sizeof(*out) && out->result==0 ? 0 : -3; }
int omen_smc_read(const char *key, double *value) {
    if (!key || !value || strlen(key)!=4) return -1;
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if (!service) return -2;
    io_connect_t c=IO_OBJECT_NULL; kern_return_t kr=IOServiceOpen(service,mach_task_self(),0,&c); IOObjectRelease(service);
    if (kr!=KERN_SUCCESS) return -2;
    Packet in={0},out={0}; in.key=fourcc(key); in.command=9;
    int r=call(c,&in,&out); if(r || out.info.size>32 || out.info.size==0) { IOServiceClose(c); return -3; }
    uint32_t type=out.info.type, size=out.info.size; in.info.size=size; in.command=5;
    r=call(c,&in,&out); IOServiceClose(c); if(r) return r;
    uint16_t raw=((uint16_t)out.bytes[0]<<8)|out.bytes[1];
    if(type==fourcc("sp78") && size==2) *value=(int16_t)raw/256.0;
    else if(type==fourcc("fpe2") && size==2) *value=raw/4.0;
    else if(type==fourcc("ui8 ") && size==1) *value=out.bytes[0];
    else if(type==fourcc("ui16") && size==2) *value=raw;
    else if(type==fourcc("flt ") && size==4) { float f; memcpy(&f,out.bytes,4); *value=f; }
    else return -4;
    return isfinite(*value) ? 0 : -4;
}
