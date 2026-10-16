import SwiftUI
import AppKit
#if canImport(OmenCore)
import OmenCore
#endif

@MainActor final class ControlModel: ObservableObject {
    @Published private(set) var serviceEnabled = UserDefaults.standard.object(forKey: "fanServiceEnabled") as? Bool ?? true
    @Published private(set) var changingService = false
    @Published private(set) var serviceMessage = ""
    @Published var snapshot = MachineSnapshot()
    @Published var bridge = FanBridgeStatus()
    @Published var settings = FanSettings()
    @Published var power = PowerSettings()
    @Published var unit: TemperatureUnit = .celsius { didSet { UserDefaults.standard.set(unit.rawValue, forKey: "temperatureUnit") } }
    @Published private(set) var applied: FanSettings?
    @Published private(set) var savedPower: PowerSettings?
    @Published private(set) var busy = false
    @Published private(set) var savingPower = false
    @Published private(set) var powerPolicy: PowerPolicy?
    @Published private(set) var loadingPower = false
    @Published private(set) var powerMessage = "Reading current macOS power settings…"
    @Published private(set) var powerHelperReady = false
    @Published private(set) var powerHelperMessage = ""
    @Published private(set) var changingPowerHelper = false
    @Published private(set) var onAC = Hardware.onAC
    @Published private(set) var status = "Connecting to the fan driver…"
    @Published private(set) var history: [FanSample] = []
    @Published private(set) var thermalOverride = false
    let isPreview: Bool
    var openDashboard: (() -> Void)?
    var openSettings: (() -> Void)?
    private let driver = FanDriver()
    private var timer: Timer?, keyTimer: Timer?
    private var gpuQueryInFlight = false
    private var gpuAttempt = Date.distantPast
    private var gpuRead = Date.distantPast
    private var gpuValue: Double?
    private var gpuMessage = "Checking NVIDIA temperature sensors…"
    private var refreshing = false, checkingKey = false, resumed = false
    private var lastOmenSequence: UInt64?
    private var lastSent: [Int] = []
    private var resumeSettings: FanSettings?
    private var previousAC: Bool?
    private var lastSampleTime = Date.distantPast
    private let defaults = UserDefaults.standard

    init(preview: Bool = false) {
        isPreview = preview
        serviceMessage = serviceEnabled ? "Service is on." : "Service is off."
        if preview {
            bridge.ready=true;bridge.available=true;bridge.cpuRPM=2400;bridge.gpuRPM=2600;bridge.version="0.4.0";bridge.minimumPercent=0
            lastSampleTime=Date();applied=FanSettings();status="Automatic cooling is active."
            snapshot.sensors=[.init(key:"TC0D",label:"CPU die",value:48,unit:"°C"),.init(key:"TCFW",label:"CPU firmware sensor",value:46,unit:"°C"),.init(key:"TG0D",label:"GPU die",value:42,unit:"°C")]
            history=(0..<21).map { i in FanSample(date: Date().addingTimeInterval(Double(i-20)*3),cpu:2400+(i%4)*100,gpu:2600+(i%3)*100) }
            return
        }
        if let data = defaults.data(forKey: "activeSettingsV4"), let v = try? JSONDecoder().decode(FanSettings.self, from: data), v.valid { settings = v; resumeSettings = v }
        if let data = defaults.data(forKey: "powerSettingsV4"), let v = try? JSONDecoder().decode(PowerSettings.self, from: data) { power = v; savedPower = v }
        unit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "°C") ?? .celsius
        savedPower = power
        refreshPowerSettings()
        guard serviceEnabled else { status = "Background fan service is off."; return }
        startMonitoring()
    }
    private func startMonitoring() {
        timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        keyTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkKey() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if let keyTimer { RunLoop.main.add(keyTimer, forMode: .common) }
        Task { await refresh() }
    }
    func setServiceEnabled(_ enabled: Bool) {
        guard !changingService, enabled != serviceEnabled else { return }
        changingService = true
        serviceMessage = ""
        Task {
            if !enabled {
                // Block new work first, then let any already issued command finish
                // before releasing the lease. No subsequent heartbeat can revive it.
                serviceEnabled = false
                timer?.invalidate(); timer = nil
                keyTimer?.invalidate(); keyTimer = nil
                while busy || refreshing || checkingKey {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                do { try await driver.stop() }
                catch { serviceMessage = error.localizedDescription }
                applied = nil; lastSent = []; history = []; snapshot = MachineSnapshot()
                bridge = FanBridgeStatus(); thermalOverride = false
                status = "Background fan service is off."
                defaults.set(false, forKey: "fanServiceEnabled")
            }
            do {
                try await Task.detached(priority: .utility) { try LoginService.configure(enabled: enabled) }.value
                if enabled {
                    serviceEnabled = true
                    defaults.set(true, forKey: "fanServiceEnabled")
                    resumed = false; previousAC = nil; lastOmenSequence = nil
                    // Resume only an accepted profile, never an unapplied draft.
                    if let data = defaults.data(forKey: "activeSettingsV4"),
                       let saved = try? JSONDecoder().decode(FanSettings.self, from: data), saved.valid {
                        resumeSettings = saved
                    } else { resumeSettings = nil }
                    startMonitoring()
                }
                if enabled { serviceMessage = "Service is on and starts quietly at login." }
                else if serviceMessage.isEmpty { serviceMessage = "Service is off; automatic firmware cooling is in charge." }
            } catch {
                serviceMessage = error.localizedDescription + (enabled ? " Service remains off." : " Monitoring is stopped, but login configuration could not be changed.")
            }
            changingService = false
        }
    }
    func temperature(gpu: Bool) -> Double? {
        snapshot.sensors.filter { $0.unit == "°C" && $0.key.hasPrefix(gpu ? "TG" : "TC") }.map(\.value).max()
    }
    var curveTemperature: Double? {
        guard let cpu = temperature(gpu: false), let gpu = temperature(gpu: true) else { return nil }
        return max(cpu,gpu)
    }
    var hasChanges: Bool { applied.map { !settings.sameRequest(as: $0) } ?? true }
    var canApply: Bool { serviceEnabled && !changingService && bridge.ready && !busy && settings.valid && hasChanges && blockReason == nil }
    var blockReason: String? {
        guard serviceEnabled else { return "Turn on the background fan service in Settings to apply a profile." }
        guard bridge.ready else { return bridge.message }
        if settings.profile == .curve && curveTemperature == nil { return "The curve needs both CPU and GPU temperatures. A missing sensor is shown as —; use Auto or Manual for now." }
        if let t = settings.targets(temperature: curveTemperature), settings.profile != .auto,
           (t.0 < Double(bridge.minimumPercent) || t.1 < Double(bridge.minimumPercent)) {
            return "Restart to load fan bridge 0.4.0 and enable targets below 70%."
        }
        return nil
    }
    var quietLoginConfigured: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.omen.login.control.plist")
        guard let data = try? Data(contentsOf: path), let plist = try? PropertyListSerialization.propertyList(from: data,format: nil) as? [String:Any] else { return false }
        return plist["ProgramArguments"] as? [String] == ["/Applications/OmenControl.app/Contents/MacOS/OmenControl","--background"] && plist["RunAtLoad"] as? Bool == true
    }
    var powerLabel: String { onAC.map { $0 ? "Plugged in" : "On battery" } ?? "Power source unavailable" }
    var powerSymbol: String { onAC.map { $0 ? "powerplug.fill" : "battery.75percent" } ?? "questionmark.circle" }
    var activeLabel: String { serviceEnabled ? (applied?.profile.rawValue ?? (bridge.ready && !bridge.manual ? "Auto" : "Unconfirmed")) : "Service off" }
    var readoutFresh: Bool { bridge.ready && Date().timeIntervalSince(lastSampleTime) < 10 }
    func rpm(_ gpu: Bool) -> Int? { readoutFresh ? (gpu ? bridge.gpuRPM : bridge.cpuRPM) : nil }
    func formattedTemperature(_ t: Double?) -> String { t.map { "\(Int(unit.value($0).rounded()))\(unit.rawValue)" } ?? "—" }
    func checkKey() async {
        guard serviceEnabled, !checkingKey else { return }; checkingKey = true; defer { checkingKey = false }
        guard let sequence = await driver.omenKeySequence() else { return }
        defer { lastOmenSequence = sequence }
        if serviceEnabled, let old = lastOmenSequence, sequence > old { openDashboard?() }
    }
    func refresh() async {
        guard serviceEnabled, !refreshing, !busy else { return }; refreshing = true; defer { refreshing = false }
        snapshot = await Task.detached(priority: .utility) { Hardware.snapshot() }.value
        guard serviceEnabled else { return }
        if !snapshot.sensors.contains(where: { $0.key.hasPrefix("TG") }) {
            if Date().timeIntervalSince(gpuRead)<10, let value=gpuValue {
                snapshot.sensors.append(.init(key:"TGRM",label:"GPU die · NVIDIA RM",value:value,unit:"°C"))
            }
            if gpuQueryInFlight && Date().timeIntervalSince(gpuAttempt)>10 {
                snapshot.gpuTemperatureStatus="NVIDIA is not returning a fresh temperature. Fan control remains responsive."
            } else if gpuValue != nil && Date().timeIntervalSince(gpuRead)>=10 {
                snapshot.gpuTemperatureStatus="The GPU temperature is stale. Waiting for a fresh NVIDIA reading."
            } else { snapshot.gpuTemperatureStatus=gpuMessage }
            requestGPUReading()
        } else { snapshot.gpuTemperatureStatus="GPU temperature read through SMC." }
        do { try await driver.heartbeat() } catch { applied = nil; status = error.localizedDescription }
        bridge = await driver.status()
        guard serviceEnabled else { return }
        if let cpu = bridge.cpuTemperature, bridge.ready { snapshot.sensors.append(.init(key: "TCFW",label: "CPU firmware sensor",value: cpu,unit: "°C")) }
        if bridge.ready {
            lastSampleTime = Date()
            history.append(FanSample(date: Date(), cpu: bridge.cpuRPM, gpu: bridge.gpuRPM))
            history.removeAll { Date().timeIntervalSince($0.date) > 60 }
        }
        let source = Hardware.onAC; onAC = source
        if let source, let policy = savedPower, policy.followSource, previousAC != source {
            var desired = applied ?? resumeSettings ?? settings
            desired.profile = source ? policy.acProfile : policy.batteryProfile
            settings = desired; resumeSettings = desired; resumed = false
        }
        previousAC = source
        if bridge.ready && !resumed {
            if let restore=resumeSettings, !settings.sameRequest(as:restore) {
                // Preserve a draft edited while initial sensors were loading.
                resumed=true
                if !bridge.manual { applied=FanSettings() }
                status="Changes not applied."
            } else if resumeSettings?.profile == .curve, curveTemperature == nil,
                      gpuQueryInFlight, Date().timeIntervalSince(gpuAttempt)<10 {
                status="Waiting for CPU and GPU temperatures before resuming the curve."
            } else {
                resumed=true
                if let restore=resumeSettings {
                    settings=restore
                    if blockReason == nil { await apply(restore) }
                    else { status=blockReason ?? "Choose a profile." }
                } else if !bridge.manual { applied=FanSettings();status="Automatic cooling is active." }
                else { status="Another fan controller is active. Quit it before applying a profile." }
            }
        }
        guard let active = applied else { return }
        if active.profile != .auto && !bridge.manual {
            applied = nil; lastSent = []; status = "The firmware returned to Auto. Apply again to resume your profile."; return
        }
        if active.profile == .auto {
            if bridge.manual { applied = nil; status = "Fan control changed outside this service. Apply a profile to resume." }
            return
        }
        // A thermal override raises the fans; it never disables firmware protection.
        let hottest = snapshot.sensors.filter { $0.unit == "°C" }.map(\.value).max()
        if snapshot.thermal == "Critical" || snapshot.thermal == "Serious" || (hottest ?? 0) >= 90 { thermalOverride = true }
        else if let hottest, hottest < 80, snapshot.thermal != "Critical", snapshot.thermal != "Serious" {
            if thermalOverride { status = "\(active.profile.rawValue) resumed after cooling boost." }
            thermalOverride = false
        }
        if thermalOverride {
            await updateTargets((100,100)); status = "Cooling boost: full speed until temperatures fall below 80°C."
        } else if let target = active.targets(temperature: curveTemperature) {
            await updateTargets(target)
        } else {
            do { try await driver.automatic() } catch { status = error.localizedDescription }
            applied = nil; lastSent = []; status = "A temperature sensor became unavailable. Returned to Auto."
        }
    }
    private func requestGPUReading() {
        guard !gpuQueryInFlight, Date().timeIntervalSince(gpuAttempt)>5 else { return }
        gpuQueryInFlight=true;gpuAttempt=Date()
        Task {
            let result=await Task.detached(priority:.utility) { Hardware.nvidiaTemperature() }.value
            gpuQueryInFlight=false
            guard serviceEnabled else { gpuValue = nil; return }
            gpuRead=Date();gpuValue=result.0;gpuMessage=result.1
            snapshot.gpuTemperatureStatus=result.1
            snapshot.sensors.removeAll { $0.key == "TGRM" }
            if let value=result.0, !snapshot.sensors.contains(where: { $0.key.hasPrefix("TG") }) {
                snapshot.sensors.append(.init(key:"TGRM",label:"GPU die · NVIDIA RM",value:value,unit:"°C"))
            }
        }
    }
    private func updateTargets(_ target: (Double,Double)) async {
        guard serviceEnabled else { return }
        let request = [Int(target.0.rounded()),Int(target.1.rounded())]
        guard request != lastSent else { return }
        do { try await driver.apply(cpu: target.0, gpu: target.1); lastSent = request }
        catch { applied = nil; status = error.localizedDescription }
    }
    func applyFans() {
        guard canApply else { return }
        let request = settings
        Task { await apply(request) }
    }
    private func apply(_ request: FanSettings) async {
        guard serviceEnabled, !busy else { return }; busy = true; defer { busy = false }
        do {
            guard let target = request.targets(temperature: curveTemperature) else { status = "Both temperature sensors are needed for this curve."; return }
            if request.profile == .auto { try await driver.automatic() }
            else { try await driver.apply(cpu: target.0, gpu: target.1) }
            applied = request; resumeSettings = request; resumed = true; thermalOverride = false
            lastSent = request.profile == .auto ? [] : [Int(target.0),Int(target.1)]
            defaults.set(try JSONEncoder().encode(request), forKey: "activeSettingsV4")
            status = "\(request.profile.rawValue) applied. Actual speeds update every 3 seconds."
            bridge = await driver.status()
        } catch { status = error.localizedDescription }
    }
    var systemPowerChanged: Bool { powerPolicy?.needsChange(power) ?? false }
    var localPowerChanged: Bool { savedPower.map { !power.sameLocalRequest(as: $0) } ?? false }
    var canSavePower: Bool {
        !savingPower && !loadingPower && !changingPowerHelper
        && (systemPowerChanged || localPowerChanged) && (!systemPowerChanged || powerHelperReady)
    }
    func refreshPowerSettings() {
        powerHelperReady = PowerHelperClient.ready
        powerHelperMessage = PowerHelperClient.description
        guard !loadingPower, !savingPower, !isPreview else { return }
        loadingPower = true
        Task {
            await readPowerSettings()
            loadingPower = false
        }
    }
    private func readPowerSettings() async {
        do {
            let current = try await Hardware.powerPolicy()
            if powerPolicy == nil || power.batteryLowPower == powerPolicy?.battery {
                if let value = current.battery { power.batteryLowPower = value }
            }
            if powerPolicy == nil || power.acLowPower == powerPolicy?.ac {
                if let value = current.ac { power.acLowPower = value }
            }
            powerPolicy = current
            powerMessage = current.battery == nil ? "macOS does not report a battery Low Power Mode policy. Plugged-in settings remain available." : "Current macOS power settings loaded."
        } catch { powerMessage = error.localizedDescription }
    }
    func enablePowerHelper() {
        guard !changingPowerHelper, !savingPower else { return }
        changingPowerHelper = true
        do { try PowerHelperClient.enable() }
        catch { powerMessage = error.localizedDescription }
        powerHelperReady = PowerHelperClient.ready
        powerHelperMessage = PowerHelperClient.description
        changingPowerHelper = false
    }
    func disablePowerHelper() {
        guard !changingPowerHelper, !savingPower else { return }
        changingPowerHelper = true
        Task {
            do { try await PowerHelperClient.disable() }
            catch { powerMessage = error.localizedDescription }
            powerHelperReady = PowerHelperClient.ready
            powerHelperMessage = PowerHelperClient.description
            changingPowerHelper = false
        }
    }
    func savePower() {
        guard canSavePower else { return }
        savingPower = true
        let requested = power
        let changeSystem = systemPowerChanged
        Task {
            do {
                if changeSystem {
                    // Re-read immediately before changing the OS, including changes
                    // made in System Settings since the dashboard last activated.
                    let current = try await Hardware.powerPolicy()
                    powerPolicy = current
                    let batteryChanged = current.battery.map { $0 != requested.batteryLowPower } ?? false
                    let acChanged = current.ac.map { $0 != requested.acLowPower } ?? false
                    if batteryChanged || acChanged {
                        try await PowerHelperClient.apply(battery: requested.batteryLowPower, ac: requested.acLowPower,
                                                          changeBattery: batteryChanged, changeAC: acChanged)
                        let verified = try await Hardware.powerPolicy()
                        powerPolicy = verified
                        guard !verified.needsChange(requested),
                              (!batteryChanged || verified.battery == requested.batteryLowPower),
                              (!acChanged || verified.ac == requested.acLowPower) else {
                            throw NSError(domain: "OmenPower", code: 5, userInfo: [NSLocalizedDescriptionKey: "macOS did not confirm the requested power settings. Refresh before retrying."])
                        }
                    }
                }
                defaults.set(try JSONEncoder().encode(requested), forKey: "powerSettingsV4")
                savedPower = requested
                previousAC = nil
                powerMessage = "Power Profile applied."
            } catch {
                let failure = error.localizedDescription
                await readPowerSettings()
                powerMessage = failure
            }
            savingPower = false
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OmenControl-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sensorText = snapshot.sensors.map { "\($0.key): \($0.value) \($0.unit)" }.joined(separator: "\n")
        let text = "OMEN Control 1.0\nBridge: \(bridge.version)\n\(bridge.message)\nProfile: \(activeLabel)\nCPU RPM: \(bridge.cpuRPM.map(String.init) ?? "unavailable")\nGPU RPM: \(bridge.gpuRPM.map(String.init) ?? "unavailable")\nCPU target: \(bridge.cpuTargetRPM ?? 0)\nGPU target: \(bridge.gpuTargetRPM ?? 0)\nPower: \(powerLabel)\nThermal: \(snapshot.thermal)\nGPU sensor: \(snapshot.gpuTemperatureStatus)\n\(sensorText)\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "Diagnostics saved." } catch { status = error.localizedDescription }
    }
}
struct FanSample: Identifiable { let id = UUID(); let date: Date; let cpu: Int?; let gpu: Int? }
