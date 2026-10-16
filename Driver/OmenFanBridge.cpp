// HP 8C78 WMAA protocol bridge. Protocol reference: Linux hp-wmi.c.
// Only allowlisted fan operations; no raw ACPI/EC API is exposed.
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/acpi/IOACPITypes.h>
#include <libkern/OSAtomic.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>
#include <kern/clock.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <IOKit/IOMessage.h>
#include "FanPolicy.h"

class OmenFanClient;
class OmenFanBridge : public IOService {
    OSDeclareDefaultStructors(OmenFanBridge)
    IOACPIPlatformDevice *device = nullptr;
    IOLock *lock = nullptr;
    IOTimerEventSource *timer = nullptr;
    IOWorkLoop *loop = nullptr;
    IONotifier *sleepNotifier = nullptr;
    OmenFanClient *owner = nullptr;
    bool ready = false, manual = false, sleeping = false;
    uint8_t minimum[2] = {}, maximum[2] = {}, target[2] = {};
    uint32_t rpm[2] = {}, zeroSamples = 0;
    unsigned discoveryAttempts = 10;
    uint64_t lease = 0, refreshAt = 0;
    uint64_t nextSample = 0, keySequence = 0;
    volatile UInt32 pendingKey = 0;
    char method[5] = "WMAA";
    static uint64_t now() { uint64_t a, n; clock_get_uptime(&a); absolutetime_to_nanoseconds(a, &n); return n / 1000000000ULL; }
    static uint32_t property32(IORegistryEntry *e, const char *key) {
        auto data = OSDynamicCast(OSData, e->getProperty(key)); uint32_t value = 0;
        if (data && data->getLength() == 4) bcopy(data->getBytesNoCopy(), &value, 4);
        return value;
    }
    bool boardMatches() {
        auto it = IORegistryIterator::iterateOver(gIOServicePlane, kIORegistryIterateRecursively);
        if (!it) return false;
        bool found = false;
        while (auto e = OSDynamicCast(IORegistryEntry, it->getNextObject())) {
            if (property32(e, "subsystem-vendor-id") == 0x103c && property32(e, "subsystem-id") == 0x8c78) { found = true; break; }
        }
        it->release(); return found;
    }
    IOReturn query(uint32_t command, const void *input, uint32_t inputSize, void *output, uint32_t outputSize) {
        if (inputSize > 128 || outputSize > 128) return kIOReturnBadArgument;
        struct Request { uint32_t signature, command, type, size; uint8_t payload[128]; } request = {};
        request.signature = 0x55434553; request.command = 0x20008; request.type = command; request.size = inputSize;
        if (inputSize) bcopy(input, request.payload, inputSize);
        auto instance = OSNumber::withNumber(0ULL, 32);
        auto mid = OSNumber::withNumber(outputSize == 0 ? 1 : outputSize <= 4 ? 2 : 3, 32);
        auto buffer = OSData::withBytes(&request, sizeof(request));
        if (!instance || !mid || !buffer) { if(instance) instance->release(); if(mid) mid->release(); if(buffer) buffer->release(); return kIOReturnNoMemory; }
        OSObject *args[3] = {instance, mid, buffer}, *result = nullptr;
        IOReturn status = device->evaluateObject(method, &result, args, 3);
        instance->release(); mid->release(); buffer->release();
        auto data = OSDynamicCast(OSData, result);
        if (status == kIOReturnSuccess) {
            if (!data || data->getLength() < 8 + outputSize) status = kIOReturnBadMedia;
            else {
                const auto bytes = static_cast<const uint8_t *>(data->getBytesNoCopy());
                uint32_t firmwareStatus; bcopy(bytes + 4, &firmwareStatus, 4);
                setProperty("LastFirmwareStatus", static_cast<unsigned long long>(firmwareStatus), 32);
                if(command==0x10 || command==0x27 || command==0x2e)setProperty("LastControlFirmwareStatus",static_cast<unsigned long long>(firmwareStatus),32);
                if (firmwareStatus) status = kIOReturnIOError;
                else if (outputSize) bcopy(bytes + 8, output, outputSize);
            }
        }
        if (result) result->release();
        setProperty("LastTransportStatus", static_cast<unsigned long long>(static_cast<uint32_t>(status)), 32);
        if(command==0x27 || command==0x2e) {
            setProperty("LastWriteCommand",static_cast<unsigned long long>(command),32);
            setProperty("LastWriteTransportStatus",static_cast<unsigned long long>(static_cast<uint32_t>(status)),32);
        }
        return status;
    }
    IOReturn setFans(uint8_t cpu, uint8_t gpu) {
        // WHCM CreateField(DAIN) must exceed 64 bits so GC2E receives a Buffer,
        // rather than a short BufferField evaluated as an Integer by ACPICA.
        uint8_t payload[16]={cpu,gpu}, ack[4]={};
        // Use the four-byte acknowledgement entry point instead of MID 1.
        return query(0x2e,payload,sizeof(payload),ack,4);
    }
    IOReturn clearMaximum() { uint8_t payload[16]={}; uint32_t ack=0; return query(0x27,payload,sizeof(payload),&ack,4); }
    void keyEvent() {
        auto arg=OSNumber::withNumber(0x80ULL,32); if(!arg)return;
        OSObject *args[1]={arg}, *object=nullptr;
        auto code=device->evaluateObject("_WED",&object,args,1); arg->release();
        setProperty("LastKeyTransportStatus",static_cast<unsigned long long>(static_cast<uint32_t>(code)),32);
        auto data=OSDynamicCast(OSData,object);
        if(code==kIOReturnSuccess && data && (data->getLength()==8 || data->getLength()==16)) {
            auto bytes=static_cast<const uint8_t *>(data->getBytesNoCopy()); uint32_t id=0,value=0;
            omenDecodeKey(bytes,data->getLength(),&id,&value);
            setProperty("LastKeyEventID",static_cast<unsigned long long>(id),32);
            setProperty("LastKeyEventData",static_cast<unsigned long long>(value),32);
            if(id==0x1d && value==0x21a5) { ++keySequence; setProperty("OmenKeySequence",keySequence,64); }
        }
        if(object)object->release();
    }
    bool table() {
        uint8_t input[4] = {}, data[128] = {};
        if (query(0x2f, input, 4, data, 128) != kIOReturnSuccess || !omenFanLimits(data,128,minimum,maximum)) return false;
        setProperty("FanTable", data, sizeof(data));
        setProperty("CPUFanMinRPM", static_cast<unsigned long long>(minimum[0])*100, 32);
        setProperty("CPUFanMaxRPM", static_cast<unsigned long long>(maximum[0])*100, 32);
        setProperty("GPUFanMinRPM", static_cast<unsigned long long>(minimum[1])*100, 32);
        setProperty("GPUFanMaxRPM", static_cast<unsigned long long>(maximum[1])*100, 32);
        return true;
    }
    bool telemetry() {
        uint8_t input = 0, data[128] = {};
        if (query(0x2d, &input, 1, data, 128) != kIOReturnSuccess || data[0] > 150 || data[1] > 150) { setProperty("TelemetryHealthy",false); return false; }
        setProperty("TelemetryHealthy",true);
        rpm[0] = data[0]*100; rpm[1] = data[1]*100;
        setProperty("CPUFanRPM", static_cast<unsigned long long>(rpm[0]), 32);
        setProperty("GPUFanRPM", static_cast<unsigned long long>(rpm[1]), 32);
        // GC2A byte 0 is CTMP in this board's ACPI. Byte 2 is deliberately
        // not labelled as GPU: its sensor identity has not been established.
        uint8_t thermalInput[4]={}, thermalData[128]={};
        bool thermalValid=query(0x2a,thermalInput,4,thermalData,128)==kIOReturnSuccess && thermalData[0]>0 && thermalData[0]<=125;
        setProperty("CPUTemperatureValid",thermalValid);
        if(thermalValid) {
            setProperty("CPUTemperatureC",static_cast<unsigned long long>(thermalData[0]),32);
            if(manual && thermalData[0]>=90) { automatic(); setProperty("ThermalFallback",true); }
        }
        return true;
    }
    IOReturn automatic() {
        if (!manual) return kIOReturnSuccess;
        auto a = clearMaximum();
        auto b = setFans(0,0);
        setProperty("LastRestoreStatus",static_cast<unsigned long long>(static_cast<uint32_t>(b==kIOReturnSuccess?a:b)),32);
        if (a == kIOReturnSuccess && b == kIOReturnSuccess) {
            manual = false; owner = nullptr; target[0] = target[1] = 0;
            setProperty("ManualActive", false); setProperty("AutomaticRestoreFailed",false); return kIOReturnSuccess;
        }
        // Stop keepalive even on restore failure; firmware timeout remains enabled.
        lease = 0; setProperty("AutomaticRestoreFailed", true);
        return kIOReturnIOError;
    }
    static void tick(OSObject *object, IOTimerEventSource *) {
        auto self = OSDynamicCast(OmenFanBridge, object); if (!self) return;
        IOLockLock(self->lock);
        if (!self->sleeping) {
            if(OSCompareAndSwap(1,0,&self->pendingKey))self->keyEvent();
            if(now() < self->nextSample) { IOLockUnlock(self->lock); self->timer->setTimeoutMS(250); return; }
            self->nextSample=now()+3;
            if(!self->ready && self->discoveryAttempts) {
                --self->discoveryAttempts;
                if(self->boardMatches()) {
                    self->discoveryAttempts=0;
                    self->ready=self->table() && self->telemetry();
                    self->setProperty("FanWritesSupported",self->ready);
                    self->setProperty("BoardVerified",true);
                }
            }
            bool sample = self->ready && self->telemetry();
            if (self->manual) {
                if (!sample || ((self->target[0] && !self->rpm[0]) || (self->target[1] && !self->rpm[1]))) ++self->zeroSamples; else self->zeroSamples = 0;
                if (now() > self->lease || self->zeroSamples >= 3) self->automatic();
                else if (now() >= self->refreshAt) {
                    uint8_t in[4] = {}, out[4] = {};
                    if (self->query(0x10, in, 4, out, 4) != kIOReturnSuccess) self->automatic();
                    else self->refreshAt = now() + 30;
                }
            }
        }
        IOLockUnlock(self->lock); self->timer->setTimeoutMS(250);
    }
    static IOReturn power(void *target, void *, UInt32 type, IOService *, void *argument, vm_size_t) {
        auto self = static_cast<OmenFanBridge *>(target);
        if (type == kIOMessageSystemWillSleep) {
            IOLockLock(self->lock); self->automatic(); self->sleeping = true; IOLockUnlock(self->lock);
            acknowledgeSleepWakeNotification(argument);
        } else if(type == kIOMessageSystemWillPowerOff || type == kIOMessageSystemWillRestart) {
            IOLockLock(self->lock); self->automatic(); self->sleeping=true; IOLockUnlock(self->lock);
            acknowledgeSleepWakeNotification(argument);
        } else if (type == kIOMessageSystemHasPoweredOn) {
            IOLockLock(self->lock); self->sleeping = false; IOLockUnlock(self->lock);
        }
        return kIOReturnSuccess;
    }
public:
    bool start(IOService *provider) override;
    IOReturn message(UInt32 type, IOService *provider, void *argument) override {
        if(type==kIOACPIMessageDeviceNotification && argument && *static_cast<uint32_t *>(argument)==0x80) {
            OSCompareAndSwap(0,1,&pendingKey); return kIOReturnSuccess;
        }
        return IOService::message(type,provider,argument);
    }
    void stop(IOService *provider) override;
    void free() override { if(lock)IOLockFree(lock); if(loop)loop->release(); IOService::free(); }
    IOReturn newUserClient(task_t task, void *security, UInt32 type, IOUserClient **client) override;
    IOReturn command(OmenFanClient *client, uint32_t selector, const uint64_t *values, uint32_t count) {
        IOLockLock(lock); IOReturn status = kIOReturnNotReady;
        if (!ready || sleeping) { IOLockUnlock(lock); return status; }
        if (selector == 1 && count == 2 && values[0] <= 100 && values[1] <= 100) {
            if (manual && owner != client) status = kIOReturnExclusiveAccess;
            else {
                uint8_t targets[2];
                if(!omenManualTarget(minimum[0],maximum[0],values[0],&targets[0]) || !omenManualTarget(minimum[1],maximum[1],values[1],&targets[1])) { IOLockUnlock(lock); return kIOReturnBadArgument; }
                uint8_t in[4]={}, out[4]={};
                manual=true; owner=client; lease=now()+20; refreshAt=now()+30; zeroSamples=0;
                uint32_t stage=0x10; status=query(0x10,in,4,out,4);
                if(status==kIOReturnSuccess){ stage=0x27;status=clearMaximum(); }
                if(status==kIOReturnSuccess){ stage=0x2e;status=setFans(targets[0],targets[1]); }
                setProperty("LastApplyStage",static_cast<unsigned long long>(stage),32);
                setProperty("LastApplyStatus",static_cast<unsigned long long>(static_cast<uint32_t>(status)),32);
                if(status!=kIOReturnSuccess)automatic();
                else { target[0]=targets[0]; target[1]=targets[1]; setProperty("ManualActive",true); setProperty("CPUFanTargetRPM",static_cast<unsigned long long>(target[0])*100,32); setProperty("GPUFanTargetRPM",static_cast<unsigned long long>(target[1])*100,32); }
            }
        } else if(selector==2 && count==0) {
            status = !manual || owner==client ? automatic() : kIOReturnExclusiveAccess;
        } else if(selector==3 && count==0) {
            if(manual && owner==client) { lease=now()+20; status=kIOReturnSuccess; } else status=kIOReturnNotOpen;
        } else status=kIOReturnBadArgument;
        IOLockUnlock(lock); return status;
    }
    void disconnected(OmenFanClient *client) { IOLockLock(lock); if(owner==client){ automatic(); owner=nullptr; } IOLockUnlock(lock); }
};

class OmenFanClient : public IOUserClient {
    OSDeclareDefaultStructors(OmenFanClient)
    OmenFanBridge *bridge = nullptr;
public:
    bool start(IOService *provider) override { bridge=OSDynamicCast(OmenFanBridge,provider); return bridge && IOUserClient::start(provider); }
    IOReturn clientClose() override { if(bridge)bridge->disconnected(this); terminate(); return kIOReturnSuccess; }
    IOReturn clientDied() override { return clientClose(); }
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *a, IOExternalMethodDispatch *, OSObject *, void *) override {
        if(!bridge || isInactive())return kIOReturnNotAttached;
        if(!a || a->asyncWakePort || a->structureInputSize || a->structureOutputSize || a->scalarOutputCount || a->scalarInputCount>2)return kIOReturnBadArgument;
        return bridge->command(this,selector,a->scalarInput,a->scalarInputCount);
    }
};
OSDefineMetaClassAndStructors(OmenFanBridge, IOService)
OSDefineMetaClassAndStructors(OmenFanClient, IOUserClient)

bool OmenFanBridge::start(IOService *provider) {
    device=OSDynamicCast(IOACPIPlatformDevice,provider); if(!device)return false;
    OSObject *object=nullptr; auto status=device->evaluateObject("_WDG",&object);
    auto data=OSDynamicCast(OSData,object); bool found=false;
    const uint8_t guid[16]={0x34,0xf0,0xb7,0x5f,0x63,0x2c,0xe9,0x45,0xbe,0x91,0x3d,0x44,0xe2,0xc7,0x07,0xe4};
    if(status==kIOReturnSuccess && data && data->getLength()%20==0) {
        auto bytes=static_cast<const uint8_t *>(data->getBytesNoCopy());
        for(unsigned i=0;i+20<=data->getLength();i+=20)if(!bcmp(bytes+i,guid,16) && bytes[i+16]=='A' && bytes[i+17]=='A' && (bytes[i+19]&2))found=true;
    }
    if(object)object->release(); if(!found || !IOService::start(provider))return false;
    lock=IOLockAlloc(); if(!lock)return false;
    setProperty("BridgeVersion","0.4.0"); setProperty("PhysicalBoard","8C78"); setProperty("ManualActive",false);
    setProperty("OmenKeySequence",0ULL,64);
    setProperty("FanWritesSupported",false); setProperty("BoardVerified",false);
    setProperty("MinimumManualPercent",0ULL,32);
    setProperty("ZeroMeansAutomatic",true); setProperty("FanStopSupported",false);
    loop=IOWorkLoop::workLoop();
    timer=IOTimerEventSource::timerEventSource(this,tick);
    if(!loop || !timer || loop->addEventSource(timer)!=kIOReturnSuccess) {
        if(timer){timer->release();timer=nullptr;} ready=false; IOService::stop(provider); return false;
    }
    sleepNotifier=registerSleepWakeInterest(power,this);
    if(!sleepNotifier){ ready=false; discoveryAttempts=0; setProperty("FanWritesSupported",false); }
    timer->setTimeoutMS(3000); registerService(); return true;
}
void OmenFanBridge::stop(IOService *provider) {
    if(timer){ timer->cancelTimeout(); loop->removeEventSource(timer); timer->release(); timer=nullptr; }
    if(sleepNotifier){ sleepNotifier->remove(); sleepNotifier=nullptr; }
    if(lock){ IOLockLock(lock); automatic(); ready=false; IOLockUnlock(lock); }
    IOService::stop(provider);
}
IOReturn OmenFanBridge::newUserClient(task_t task, void *security, UInt32 type, IOUserClient **handler) {
    if(type!=0)return kIOReturnUnsupported;
    // Restrict to the active local session; no network or arbitrary EC access.
    if(IOUserClient::clientHasPrivilege(security,kIOClientPrivilegeLocalUser)!=kIOReturnSuccess || IOUserClient::clientHasPrivilege(security,kIOClientPrivilegeForeground)!=kIOReturnSuccess)return kIOReturnNotPrivileged;
    auto client=new OmenFanClient;
    if(!client)return kIOReturnNoMemory;
    if(!client->initWithTask(task,security,type)) { client->release(); return kIOReturnError; }
    if(!client->attach(this)) { client->release(); return kIOReturnError; }
    if(!client->start(this)) { client->detach(this); client->release(); return kIOReturnError; }
    *handler=client; return kIOReturnSuccess;
}
