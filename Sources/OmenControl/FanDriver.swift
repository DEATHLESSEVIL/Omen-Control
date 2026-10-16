import Foundation
import IOKit

struct FanBridgeStatus: Sendable {
    var available = false
    var ready = false
    var manual = false
    var cpuRPM: Int?
    var gpuRPM: Int?
    var cpuTargetRPM: Int?
    var gpuTargetRPM: Int?
    var message = "Fan bridge not loaded. Reboot with OmenFanBridge.kext to connect Apply."
    var cpuTemperature: Double?
    var minimumPercent = 70
    var version = "unknown"
    var cpuMinRPM = 2000
    var gpuMinRPM = 2300
    var cpuMaxRPM = 6000
    var gpuMaxRPM = 6300
    var omenKeySequence: UInt64?
}

actor FanDriver {
    private var connection: io_connect_t = 0
    private var controlling = false

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func status() -> FanBridgeStatus {
        var result = FanBridgeStatus()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("OmenFanBridge"))
        guard service != 0 else { return result }
        defer { IOObjectRelease(service) }
        result.available = true
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            result.message = "Fan bridge properties could not be read."; return result
        }
        if dictionary["CPUTemperatureValid"] as? Bool == true { result.cpuTemperature = (dictionary["CPUTemperatureC"] as? NSNumber)?.doubleValue }
        let supported = dictionary["FanWritesSupported"] as? Bool == true
        result.manual = dictionary["ManualActive"] as? Bool == true
        result.cpuRPM = (dictionary["CPUFanRPM"] as? NSNumber)?.intValue
        result.gpuRPM = (dictionary["GPUFanRPM"] as? NSNumber)?.intValue
        result.cpuTargetRPM = (dictionary["CPUFanTargetRPM"] as? NSNumber)?.intValue
        result.gpuTargetRPM = (dictionary["GPUFanTargetRPM"] as? NSNumber)?.intValue
        result.omenKeySequence = (dictionary["OmenKeySequence"] as? NSNumber)?.uint64Value
        result.version = dictionary["BridgeVersion"] as? String ?? "unknown"
        result.minimumPercent = (dictionary["MinimumManualPercent"] as? NSNumber)?.intValue ?? 70
        result.cpuMinRPM = (dictionary["CPUFanMinRPM"] as? NSNumber)?.intValue ?? 2000
        result.gpuMinRPM = (dictionary["GPUFanMinRPM"] as? NSNumber)?.intValue ?? 2300
        result.cpuMaxRPM = (dictionary["CPUFanMaxRPM"] as? NSNumber)?.intValue ?? 6000
        result.gpuMaxRPM = (dictionary["GPUFanMaxRPM"] as? NSNumber)?.intValue ?? 6300
        guard ["0.3.1", "0.4.0"].contains(result.version) else {
            result.message = "Reboot to load the installed fan bridge. The currently running driver is \(dictionary["BridgeVersion"] ?? "unknown")."
            return result
        }
        guard dictionary["TelemetryHealthy"] as? Bool == true else {
            result.message = "RPM query failed; displayed readings may be stale. Apply is unavailable until telemetry recovers."
            return result
        }
        if !supported {
            result.message = "Bridge loaded, but fan-table/RPM validation failed. Apply remains unavailable. Transport: \(dictionary["LastTransportStatus"] ?? "unknown"), firmware: \(dictionary["LastFirmwareStatus"] ?? "unknown")."
            return result
        }
        if connection == 0 {
            let code = IOServiceOpen(service, mach_task_self_, 0, &connection)
            guard code == KERN_SUCCESS else {
                result.message = "Fan bridge access denied (\(code)). Run from the active local desktop session."; return result
            }
        }
        result.ready = true
        result.message = result.manual ? "Fixed manual control is active. RPM readback is shown below." : "Fan bridge ready. Firmware automatic control is active."
        if dictionary["AutomaticRestoreFailed"] as? Bool == true {
            result.message = "Automatic restore command failed. Keepalive stopped; firmware timeout is the fallback. Restart the laptop if cooling is abnormal."
        }
        return result
    }

    private func send(_ selector: UInt32, _ arguments: [UInt64] = []) throws {
        guard connection != 0 else { throw NSError(domain: "OmenControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fan driver is not connected."]) }
        let result = arguments.withUnsafeBufferPointer { inputs in
            IOConnectCallScalarMethod(connection, selector, inputs.baseAddress, UInt32(inputs.count), nil, nil)
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: "OmenControl", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Fan command failed (\(String(format: "0x%08X", UInt32(bitPattern: result)))). \(failureDetail()) The request was not confirmed."])
        }
    }
    private func failureDetail() -> String {
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("OmenFanBridge"))
        guard service != 0 else { return "Bridge unavailable." }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0)==KERN_SUCCESS,
              let p=properties?.takeRetainedValue() as? [String: Any] else { return "Diagnostics unavailable." }
        let stage=(p["LastApplyStage"] as? NSNumber)?.uint32Value ?? 0
        let transport=(p["LastApplyStatus"] as? NSNumber)?.uint32Value ?? 0
        let firmware=(p["LastControlFirmwareStatus"] as? NSNumber)?.uint32Value ?? 0
        return String(format:"Stage 0x%02X, transport 0x%08X, firmware %u.",stage,transport,firmware)
    }

    func apply(cpu: Double, gpu: Double) throws {
        guard cpu.isFinite, gpu.isFinite, (0...100).contains(cpu), (0...100).contains(gpu) else {
            throw NSError(domain: "OmenControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose a value between 0 and 100%."])
        }
        try send(1, [UInt64(cpu.rounded()), UInt64(gpu.rounded())]); controlling = true
    }
    func automatic() throws { try send(2); controlling = false }
    func stop() throws {
        defer {
            if connection != 0 { IOServiceClose(connection); connection = 0 }
            controlling = false
        }
        if controlling { try automatic() }
    }
    func heartbeat() throws {
        guard controlling else { return }
        do { try send(3) } catch { controlling = false; throw error }
    }
    func omenKeySequence() -> UInt64? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("OmenFanBridge"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "OmenKeySequence" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint64Value
    }
}
