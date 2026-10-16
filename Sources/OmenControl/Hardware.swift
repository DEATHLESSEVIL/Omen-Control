import Foundation
#if canImport(OmenCore)
import OmenCore
#endif
import SMCReader
import IOKit.ps
import IOKit
import Darwin

struct SensorReading: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let value: Double
    let unit: String
}
struct MachineSnapshot {
    var sensors: [SensorReading] = []
    var fanCount: Int? = nil
    var logicalCPUs = ProcessInfo.processInfo.activeProcessorCount
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var thermal = "Unknown"
    var gpuTemperatureStatus = "No GPU temperature sensor is exposed by SMC."
}
enum Hardware {
    // Machine identity is stable; do not repeat registry walks on telemetry ticks.
    static let cpuName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string",nil,&size,nil,0) == 0, size > 1 else { return "Processor unavailable" }
        var bytes = [CChar](repeating: 0,count: size)
        guard sysctlbyname("machdep.cpu.brand_string",&bytes,&size,nil,0) == 0 else { return "Processor unavailable" }
        return String(cString: bytes).replacingOccurrences(of: "(R)",with: "").replacingOccurrences(of: "(TM)",with: "").trimmingCharacters(in: .whitespaces)
    }()
    static let gpuIdentity: (name: String,vendor: String) = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOPCIDevice"),&iterator) == KERN_SUCCESS else { return ("Graphics processor unavailable", "unknown") }
        defer { IOObjectRelease(iterator) }
        var candidates: [(String,String)] = []
        func bytes(_ entry: io_registry_entry_t,_ key: String) -> Data? { IORegistryEntryCreateCFProperty(entry,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Data }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let cls = bytes(entry,"class-code"),cls.count >= 3,cls[2] == 3 else { continue }
            let data = bytes(entry,"vendor-id") ?? Data()
            let vendorID = data.count >= 2 ? Int(data[0]) | Int(data[1]) << 8 : 0
            let vendor = vendorID == 0x10de ? "nvidia" : vendorID == 0x1002 ? "amd" : vendorID == 0x8086 ? "intel" : "unknown"
            let property = IORegistryEntryCreateCFProperty(entry,"model" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()
            let name = (property as? String) ?? (property as? Data).flatMap { String(data: $0,encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
            candidates.append((name ?? "Graphics processor",vendor))
        }
        // Prefer a discrete GPU to an integrated display controller.
        return candidates.first(where: { $0.1 == "nvidia" || $0.1 == "amd" }) ?? candidates.first ?? ("Graphics processor unavailable","unknown")
    }()
    static func read(_ key: String) -> Double? {
        var value = 0.0
        return key.withCString { omen_smc_read($0, &value) } == 0 ? value : nil
    }
    static func snapshot() -> MachineSnapshot {
        var result = MachineSnapshot()
        for (key, label) in [("TC0P", "CPU proximity"), ("TC0D", "CPU die"), ("TC0E", "CPU PECI"), ("TC0F", "CPU PECI 2"), ("TG0D", "GPU die"), ("TG0P", "GPU proximity"), ("TG0H", "GPU heatsink")] {
            if let value = read(key), (0...125).contains(value) { result.sensors.append(.init(key: key, label: label, value: value, unit: "°C")) }
        }
        if let count = read("FNum"), count >= 0, count <= 8, count.rounded() == count {
            result.fanCount = Int(count)
            for index in 0..<Int(count) {
                let key = "F\(index)Ac"
                if let rpm = read(key), (0...15000).contains(rpm) { result.sensors.append(.init(key: key, label: "Fan \(index + 1)", value: rpm, unit: "RPM")) }
            }
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = "Nominal"
        case .fair: result.thermal = "Fair"
        case .serious: result.thermal = "Serious"
        case .critical: result.thermal = "Critical"
        @unknown default: result.thermal = "Unknown"
        }
        return result
    }
    static func nvidiaTemperature() -> (Double?, String) {
        var value=0.0
        var message=[CChar](repeating:0,count:256)
        let code=omen_nvidia_temperature(&value,&message,message.count)
        return (code == 0 ? value : nil,String(cString:message))
    }
    static var onAC: Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        let value = type as String
        if value == kIOPSACPowerValue { return true }
        if value == kIOPSBatteryPowerValue { return false }
        return nil
    }
    // Read-only query. Missing battery policy is represented as unavailable.
    static func powerPolicy() async throws -> PowerPolicy {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "custom"]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, let policy = PowerPolicy.parse(String(decoding: data, as: UTF8.self)) else {
                throw NSError(domain: "OmenPower", code: 4, userInfo: [NSLocalizedDescriptionKey: "macOS did not report readable Low Power Mode settings. No settings were changed."])
            }
            return policy
        }.value
    }
}
