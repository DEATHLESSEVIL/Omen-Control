import AppKit
import SwiftUI
#if canImport(OmenCore)
import OmenCore
#endif

enum HardwareArtwork: String,CaseIterable,Identifiable {
    case chip = "Chip Image"
    case product = "Product Image"
    var id: String { rawValue }
}

@MainActor final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDockWhenActive")
            NotificationCenter.default.post(name: .omenDockPreferenceChanged, object: nil)
        }
    }
    @Published var hardwareArtwork: HardwareArtwork {
        didSet { UserDefaults.standard.set(hardwareArtwork.rawValue,forKey: "hardwareArtwork") }
    }
    private init() {
        hardwareArtwork = HardwareArtwork(rawValue: UserDefaults.standard.string(forKey: "hardwareArtwork") ?? "") ?? .chip
        showInDock = UserDefaults.standard.object(forKey: "showInDockWhenActive") as? Bool ?? true
    }
}
extension Notification.Name {
    static let omenDockPreferenceChanged = Notification.Name("OMENDockPreferenceChanged")
}

/// The controller stays in this app; launchd starts it quietly at login.
/// Disabling the login job does not terminate the Settings window.
enum LoginService {
    static func configure(enabled: Bool) throws {
        let manager = FileManager.default
        let directory = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("local.omen.login.control.plist")
        let plist: [String: Any] = [
            "Label": "local.omen.login.control",
            "ProgramArguments": ["/Applications/OmenControl.app/Contents/MacOS/OmenControl", "--background"],
            "RunAtLoad": enabled, "LimitLoadToSessionType": ["Aqua"],
            "ProcessType": "Interactive", "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        let target = "gui/\(getuid())/local.omen.login.control"
        try run([enabled ? "enable" : "disable", target])
        if enabled, (try? run(["print", target])) == nil {
            try run(["bootstrap", "gui/\(getuid())", url.path])
        }
    }
    @discardableResult private static func run(_ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "OMENLoginService", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Login service could not be updated. \(detail)"])
        }
        return true
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: ControlModel
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        FittedPage(idealHeight: 660) {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(AppType.title)
            VStack(alignment: .leading,spacing: 8) {
                Text("Appearance").font(AppType.heading)
                Picker("Hardware artwork",selection: $preferences.hardwareArtwork) {
                    ForEach(HardwareArtwork.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show in Dock while a window is open", isOn: $preferences.showInDock)
                Text("Closing all windows hides the Dock icon. Fan control can keep running in the menu bar.")
                    .font(AppType.body).foregroundStyle(.secondary)
            }
            HStack {
                Text("Temperature unit")
                Spacer()
                Picker("Temperature unit", selection: $model.unit) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 116)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Background fan service", isOn: Binding(get: { model.serviceEnabled }, set: { model.setServiceEnabled($0) }))
                    .disabled(model.changingService)
                Text("Runs quietly at login and keeps your fan profile active after you close the window. Turning it off releases fan control to the firmware and stops monitoring and OMEN-key handling.")
                    .font(AppType.body).foregroundStyle(.secondary)
                Text(model.serviceMessage).font(AppType.body).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Power access").font(AppType.heading)
                Text(model.powerHelperMessage).font(AppType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.powerHelperReady {
                    Button("Disable power access") { model.disablePowerHelper() }.disabled(model.changingPowerHelper || model.savingPower)
                } else {
                    Button("Enable power access…") { model.enablePowerHelper() }.disabled(model.changingPowerHelper || model.savingPower)
                }
            }
            Spacer(minLength: 0)
        }.padding(24)
        }
        .frame(minWidth: 420,idealWidth: 460,maxWidth: .infinity,minHeight: 0,idealHeight: 660,maxHeight: .infinity).background(TranslucentBackground(material: .underWindowBackground)).toggleStyle(.switch).tint(.accentColor).onAppear { model.refreshPowerSettings() }
    }
}
