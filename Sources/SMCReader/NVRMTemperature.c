// Narrow NVIDIA RM temperature reader. ABI definitions follow NVIDIA r610
// MIT-licensed SDK headers; see THIRD-PARTY-NOTICES.md. No SET, GPU startup,
// power, clocks, framebuffer, BAR or memory-mapping commands are issued.
#include "SMCReader.h"
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint32_t root,parent,object,cls; uint64_t params; uint32_t size,status; } RMAlloc;
typedef struct { uint32_t client,object,command,flags; uint64_t params; uint32_t size,status; } RMControl;
typedef struct { uint32_t root,parent,object,status; } RMFree;
typedef struct { uint32_t id,share,targetClient,targetDevice,flags,pad; uint64_t vaSize,vaStart,vaLimit; uint32_t vaMode,tail; } DeviceParams;
typedef struct { uint32_t result,executed,opcode,operand[8]; } ThermalInstruction;
typedef struct { uint32_t version,revision,instructionSize,flags,successful,count; ThermalInstruction list[32]; } ThermalParams;
_Static_assert(sizeof(RMAlloc)==32 && offsetof(RMAlloc,params)==16,"NVOS21 ABI");
_Static_assert(sizeof(RMControl)==32 && offsetof(RMControl,params)==16,"NVOS54 ABI");
_Static_assert(sizeof(DeviceParams)==56,"NV0080 ABI");
_Static_assert(sizeof(ThermalInstruction)==44 && sizeof(ThermalParams)==1432,"NV2080 thermal ABI");

static int escape(io_connect_t c,uint32_t command,void *data,size_t size,uint32_t *transport) {
    uint64_t scalar=command;size_t outputSize=size;
    kern_return_t r=IOConnectCallMethod(c,1,&scalar,1,data,size,NULL,NULL,data,&outputSize);
    *transport=(uint32_t)r;return r==KERN_SUCCESS && outputSize==size;
}
static int allocate(io_connect_t c,uint32_t root,uint32_t parent,uint32_t object,uint32_t cls,void *params,uint32_t size,uint32_t *created,uint32_t *transport,uint32_t *status) {
    RMAlloc a={root,parent,object,cls,(uint64_t)(uintptr_t)params,size,UINT32_MAX};
    int ok=escape(c,0x2b,&a,sizeof(a),transport);*status=a.status;*created=a.object;
    return ok && a.status==0 && a.object!=0;
}
static int thermal(io_connect_t c,uint32_t root,uint32_t sub,ThermalParams *p,uint32_t *transport,uint32_t *status) {
    p->version=1;p->revision=0;p->instructionSize=sizeof(ThermalInstruction);p->flags=1;p->successful=0;
    for(uint32_t i=0;i<p->count;++i){p->list[i].executed=0;p->list[i].result=UINT32_MAX;}
    RMControl ctl={root,sub,0x20800513,0,(uint64_t)(uintptr_t)p,sizeof(*p),UINT32_MAX};
    int ok=escape(c,0x2a,&ctl,sizeof(ctl),transport);*status=ctl.status;
    return ok && ctl.status==0;
}
static int valid(const ThermalInstruction *p){return p->executed && p->result==0;}

int omen_nvidia_temperature(double *value,char *message,size_t capacity) {
    if(!value || !message || !capacity)return -1;
    *value=0;io_connect_t c=0;uint32_t root=0,device=0,sub=0,transport=0,status=0;
    const char *stage="open";int result=-1;
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("NVRM"));
    if(!s){snprintf(message,capacity,"NVIDIA RM temperature interface is not loaded.");return -1;}
    CFTypeRef id=IORegistryEntryCreateCFProperty(s,CFSTR("CFBundleIdentifier"),kCFAllocatorDefault,0);
    int matches=id && CFGetTypeID(id)==CFStringGetTypeID() && CFEqual(id,CFSTR("com.nullmoth.NVRM"));
    if(id)CFRelease(id);
    if(!matches){IOObjectRelease(s);snprintf(message,capacity,"NVIDIA driver temperature interface is not recognized.");return -1;}
    transport=(uint32_t)IOServiceOpen(s,mach_task_self(),0,&c);IOObjectRelease(s);
    if(transport!=KERN_SUCCESS)goto done;
    stage="client allocation";
    if(!allocate(c,0,0,0,0x41,NULL,0,&root,&transport,&status))goto done;
    DeviceParams dp={0};
    stage="device allocation";
    if(!allocate(c,root,root,0x71000001,0x80,&dp,sizeof(dp),&device,&transport,&status))goto done;
    uint32_t subIndex=0;
    stage="subdevice allocation";
    if(!allocate(c,root,device,0x71000002,0x2080,&subIndex,sizeof(subIndex),&sub,&transport,&status))goto done;
    ThermalParams p={0};p.count=1;p.list[0].opcode=0x500;
    stage="sensor enumeration";
    if(!thermal(c,root,sub,&p,&transport,&status) || !valid(&p.list[0]))goto done;
    uint32_t count=p.list[0].operand[0];
    if(count==0 || count>32){snprintf(message,capacity,"NVIDIA returned no supported thermal sensors (count %u).",count);goto cleanup;}
    memset(&p,0,sizeof(p));p.count=count;
    for(uint32_t i=0;i<count;++i){p.list[i].opcode=0x520;p.list[i].operand[0]=i;}
    stage="sensor target mapping";
    if(!thermal(c,root,sub,&p,&transport,&status))goto done;
    uint32_t target[32];
    for(uint32_t i=0;i<count;++i)target[i]=valid(&p.list[i])?p.list[i].operand[1]:UINT32_MAX;
    memset(&p,0,sizeof(p));p.count=count;
    for(uint32_t i=0;i<count;++i){p.list[i].opcode=0x101;p.list[i].operand[0]=target[i];}
    stage="target classification";
    if(!thermal(c,root,sub,&p,&transport,&status))goto done;
    uint32_t gpu[32],gpuCount=0;
    for(uint32_t i=0;i<count;++i)if(valid(&p.list[i]) && p.list[i].operand[1]==1)gpu[gpuCount++]=i;
    if(!gpuCount){snprintf(message,capacity,"NVIDIA exposes thermal sensors, but none identifies the GPU die.");goto cleanup;}
    memset(&p,0,sizeof(p));p.count=gpuCount;
    for(uint32_t i=0;i<gpuCount;++i){p.list[i].opcode=0x1500;p.list[i].operand[0]=gpu[i];}
    stage="GPU sensor reading";
    if(!thermal(c,root,sub,&p,&transport,&status))goto done;
    int32_t hottest=0,lastRaw=0;int got=0;
    for(uint32_t i=0;i<gpuCount;++i)if(valid(&p.list[i])){
        int32_t raw=(int32_t)p.list[i].operand[1];lastRaw=raw;
        // Do not guess a scale for an undocumented/out-of-range response.
        if(raw>0 && raw<=125){if(raw>hottest)hottest=raw;got=1;}
    }
    if(got){*value=hottest;result=0;snprintf(message,capacity,"GPU die read through NVIDIA RM thermal sensors.");}
    else snprintf(message,capacity,"NVIDIA thermal response is unavailable or has unvalidated units (raw %d).",lastRaw);
    goto cleanup;
done:
    snprintf(message,capacity,"NVIDIA temperature query failed at %s (IO 0x%08x, RM 0x%08x).",stage,transport,status);
cleanup:
    if(c && root){RMFree f={root,0,root,UINT32_MAX};uint32_t ignored;escape(c,0x29,&f,sizeof(f),&ignored);}
    if(c)IOServiceClose(c);
    return result;
}
