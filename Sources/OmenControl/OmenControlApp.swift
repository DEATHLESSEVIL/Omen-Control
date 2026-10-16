import AppKit
import SwiftUI
#if canImport(OmenCore)
import OmenCore
#endif

@main struct OmenControlApp {
    @MainActor static func main() {
        do { if try FanFrameRenderer.exportFramesIfRequested() { return } } catch { print(error); return }
        if CommandLine.arguments.contains("--read-nvidia-temperature") {
            let reading=Hardware.nvidiaTemperature()
            print("GPU temperature: \(reading.0.map { String($0) } ?? "unavailable") °C\n\(reading.1)")
            return
        }
        if CommandLine.arguments.contains("--background"), UserDefaults.standard.object(forKey: "fanServiceEnabled") as? Bool == false { return }
        let app = NSApplication.shared
        // One owner of the driver lease, including when Finder opens a running service.
        if !CommandLine.arguments.contains("--render-preview"), !CommandLine.arguments.contains("--render-menu-preview"), let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.omen.control").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if !CommandLine.arguments.contains("--background") {
                DistributedNotificationCenter.default().postNotificationName(.init("local.omen.control.show"), object: nil)
                running.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }
        let delegate = AppController()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ControlModel(preview: CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--render-menu-preview"))
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarWindow?
    private var dashboard: NSWindow?
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index=CommandLine.arguments.firstIndex(of:"--render-menu-preview"), CommandLine.arguments.count>index+1 {
            model.settings.profile = .manual; model.settings.cpu=30; model.settings.gpu=70
            let view=NSHostingView(rootView:MenuPanel(model:model,open:{}))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:MenuLayout.size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView=view;window.setContentSize(MenuLayout.size)
            view.layoutSubtreeIfNeeded();dashboard=window
            let path=CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                if let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:rep)
                    if let data=rep.representation(using:.png,properties:[:]) {try? data.write(to:URL(fileURLWithPath:path))}
                }
                print("Menu preview: \(view.bounds.width) × \(view.bounds.height) points")
                NSApp.terminate(nil)
            }
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateDockVisibility), name: .omenDockPreferenceChanged, object: nil)
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openDashboard = { [weak self] in self?.showDashboard() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "OMEN Control")
            button.toolTip = "OMEN Control — fan speeds and profiles"
            button.target = self; button.action = #selector(togglePopover)
        }
        menuPanel = MenuBarWindow(rootView: MenuPanel(model: model, open: { [weak self] in self?.showDashboard() }), size: MenuLayout.size)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showDashboard), name: .init("local.omen.control.show"), object: nil)
        buildMenu()
        if !CommandLine.arguments.contains("--background") { showDashboard() }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index+1 {
            let path=CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in
                guard let view=self?.dashboard?.contentView, let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { NSApp.terminate(nil);return }
                view.cacheDisplay(in:view.bounds,to:rep)
                if let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:path)) }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPowerSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if menuPanel?.isVisible == true { menuPanel?.dismiss() }
        else { menuPanel?.present(below: button) }
    }
    @objc func showDashboard() {
        menuPanel?.dismiss()
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 780,height: 860), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Omen Control Alpha 1.0V"; window.minSize = NSSize(width: 700,height: 500)
            window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.toolbarStyle = .unified
            let container = NSView(frame: NSRect(x: 0,y: 0,width: 780,height: 860))
            container.autoresizingMask = [.width,.height]
            container.wantsLayer = true
            container.layer?.masksToBounds = true
            window.contentView = container
            let backdrop = NSVisualEffectView()
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            container.addSubview(backdrop)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: container.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            let host = NSHostingView(rootView: Dashboard(model: model))
            host.sizingOptions = [] // AppKit owns window size; SwiftUI must not expand it.
            host.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(host)
            // The material fills the complete frame, including behind the native
            // traffic lights. Content stays below the system title-bar guide.
            let layout = window.contentLayoutGuide as! NSLayoutGuide
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                host.topAnchor.constraint(equalTo: layout.topAnchor),
                host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
            ])
            window.delegate = self
            fitToScreen(window); dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil); updateDockVisibility(); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() {
        menuPanel?.dismiss()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Omen Control Alpha 1.0V — Settings"
            window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.delegate = self
            let host = NSHostingView(rootView: AppSettingsView(model: model))
            host.sizingOptions = []
            window.contentView = host
            fitToScreen(window); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateDockVisibility(); NSApp.activate(ignoringOtherApps: true)
    }
    private func fitToScreen(_ window: NSWindow) {
        guard let available = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 12,dy: 12) else { window.center(); return }
        window.maxSize = NSSize(width: min(1200,available.width),height: min(950,available.height))
        var frame = window.frame
        frame.size.width = min(frame.width,available.width)
        frame.size.height = min(frame.height,available.height)
        window.minSize = NSSize(width: min(window.minSize.width,available.width),height: min(window.minSize.height,available.height))
        frame.origin = NSPoint(x: available.midX - frame.width / 2,y: available.midY - frame.height / 2)
        window.setFrame(frame,display: false)
    }
    @objc private func updateDockVisibility() { updateDock(excluding: nil) }
    private func updateDock(excluding closing: NSWindow?) {
        let visible = [dashboard, settingsWindow].compactMap { $0 }.contains { $0 !== closing && $0.isVisible }
        NSApp.setActivationPolicy(AppPreferences.shared.showInDock && visible ? .regular : .accessory)
    }
    func windowWillClose(_ notification: Notification) {
        updateDock(excluding: notification.object as? NSWindow)
    }
    private func buildMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        let open = NSMenuItem(title: "Open OMEN Control", action: #selector(showDashboard), keyEquivalent: "1"); open.target = self; appMenu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OMEN Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editRoot = NSMenuItem(); menu.addItem(editRoot); let edit = NSMenu(title: "Edit"); editRoot.submenu = edit
        for (title, action, key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        NSApp.mainMenu = menu
    }
}

private let accent = Color.accentColor
struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(12).frame(maxWidth: .infinity,alignment: .leading).background(Color.primary.opacity(0.035),in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06))) }
}
// Keep native point sizes identical on Overview, Power Profile and Settings.
// Flexible spacing fills the window without applying a raster/text transform.
enum AppType {
    static let body = Font.system(size: 12)
    static let heading = Font.system(size: 13,weight: .semibold)
    static let title = Font.system(size: 24,weight: .semibold)
    static let reading = Font.system(size: 28,weight: .medium)
}
struct FittedPage<Content: View>: View {
    let idealHeight: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        content.font(AppType.body)
            .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top)
    }
}
struct Dashboard: View {
    @ObservedObject var model: ControlModel
    @State private var powerPage = false
    var body: some View {
        FittedPage(idealHeight: powerPage ? 700 : 900) {
        VStack(spacing: 10) {
            if model.isPreview { Text("Design preview · sample readings").font(AppType.body).foregroundStyle(.secondary) }
            HStack(alignment: .top) {
                VStack(alignment: .leading,spacing: 5) {
                    Text("Omen Control Alpha 1.0V").font(AppType.title)
                    Text(powerPage ? "Power Profile" : "Cooling, at a glance.").foregroundStyle(.secondary)
                    Label(model.powerLabel,systemImage: model.powerSymbol).font(AppType.body).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing,spacing: 12) {
                    Button { model.openSettings?() } label: { Image(systemName: "gearshape").font(.title3) }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                    Button { powerPage.toggle() } label: {
                        Label(powerPage ? "Cooling" : "Power Profile",systemImage: powerPage ? "fanblades" : "bolt.fill")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            if powerPage {
                PowerPanel(model: model)
            } else {
                    HStack(spacing: 16) { FanCard(model: model,gpu: false); FanCard(model: model,gpu: true) }
                    HStack(alignment: .top,spacing: 16) { TemperatureCard(model: model,gpu: false); TemperatureCard(model: model,gpu: true) }
                Surface { VStack(alignment: .leading,spacing: 10) {
                    HStack { Text("Fan control").font(AppType.heading); Spacer(); Text("Active: \(model.activeLabel)").font(AppType.body).foregroundStyle(accent) }
                    ProfilePicker(selection: $model.settings.profile)
                    Text(model.settings.profile.explanation).font(AppType.body).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                    if model.settings.profile == .manual { FanSliders(model: model) }
                    if model.settings.profile == .curve { CurveEditor(model: model) }
                    if model.settings.profile == .performance { Label("100% CPU · 100% GPU",systemImage: "wind").foregroundStyle(accent) }
                    if model.settings.profile == .eco { Text("30% CPU · 30% GPU requested").font(AppType.body).foregroundStyle(accent) }
                    if model.settings.profile != .auto {
                        Text("Minimum manual speed: CPU \(model.bridge.cpuMinRPM) · GPU \(model.bridge.gpuMinRPM) RPM. Lower requests stay at these limits. 0% returns that fan to Auto; this BIOS cannot turn fans off.")
                            .font(AppType.body).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                    }
                    Divider()
                    ApplyRow(model: model)
                } }
            }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "menubar.rectangle"); Text("Keeps running in the menu bar when you close this window.")
                Spacer(); Button("Diagnostics…") { model.exportDiagnostics() }.buttonStyle(.link)
            }.font(AppType.body).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: 960,maxHeight: .infinity,alignment: .top).frame(maxWidth: .infinity).tint(accent)
        }
    }
}
struct FanCard: View {
    @ObservedObject var model: ControlModel
    let gpu: Bool
    var body: some View {
        Surface { VStack(alignment: .leading,spacing: 8) {
            HStack {
                VStack(alignment: .leading,spacing: 7) {
                    Text(gpu ? "GPU fan" : "CPU fan").font(AppType.heading)
                    HStack(alignment: .firstTextBaseline,spacing: 5) {
                        Text(model.rpm(gpu).map(String.init) ?? "—").font(AppType.reading).monospacedDigit().contentTransition(.numericText())
                        Text("RPM").font(AppType.body).foregroundStyle(.secondary)
                    }
                    Text("Speed").font(AppType.body).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                FanRotor(rpm: model.rpm(gpu)).frame(width: 81.9,height: 81.9).accessibilityHidden(true)
            }
            RPMHistory(samples: model.history,gpu: gpu,maximum: gpu ? model.bridge.gpuMaxRPM : model.bridge.cpuMaxRPM).frame(height: 26)
            HStack { Text("Last minute"); Spacer(); Text("3s · 100 RPM steps") }.font(AppType.body).foregroundStyle(.secondary)
        } }.help("Actual firmware readback, in 100 RPM steps. Animation follows measured RPM at 1/240 speed.")
    }
}
struct RPMHistory: View {
    let samples: [FanSample]; let gpu: Bool; let maximum: Int
    var body: some View {
        Canvas { context,size in
            var baseline=Path(); baseline.move(to: .init(x:0,y:size.height-1));baseline.addLine(to: .init(x:size.width,y:size.height-1))
            context.stroke(baseline,with: .color(.secondary.opacity(0.15)),lineWidth: 1)
            var path=Path();var started=false
            let end = samples.last?.date ?? Date()
            for sample in samples {
                guard let rpm = gpu ? sample.gpu : sample.cpu else { started=false;continue }
                let x=max(0,size.width*(1+sample.date.timeIntervalSince(end)/60))
                let y=size.height*(1-min(1,Double(rpm)/Double(max(1,maximum))))
                if started { path.addLine(to: .init(x:x,y:y)) } else { path.move(to: .init(x:x,y:y));started=true }
            }
            context.stroke(path,with: .color(accent.opacity(0.8)),style: .init(lineWidth: 1.8,lineCap: .round,lineJoin: .round))
        }.accessibilityLabel("Measured fan RPM over the last minute")
    }
}
private struct TemperatureArtwork: View {
    let gpu: Bool
    @ObservedObject private var preferences = AppPreferences.shared
    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["cpu", "gpu", "gpu-amd", "gpu-blank"] {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("LocalFanArtwork/\(name)-icon@2x.png"),let image = NSImage(contentsOf: url) { result[name] = image }
        }
        for name in ["nvidia-logo", "intel-core-i7", "geforce-rtx"] {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Branding/\(name).png"),let image = NSImage(contentsOf: url) { result[name] = image }
        }
        return result
    }()
    private var vendor: String { Hardware.gpuIdentity.vendor }
    private var chip: NSImage? { Self.images[gpu ? (vendor == "amd" ? "gpu-amd" : vendor == "nvidia" ? "gpu-blank" : "gpu") : "cpu"] }
    private var product: NSImage? {
        if gpu { return vendor == "nvidia" ? Self.images["geforce-rtx"] : nil }
        return Hardware.cpuName.lowercased().contains("i7") ? Self.images["intel-core-i7"] : nil
    }
    var body: some View {
        Group {
            if preferences.hardwareArtwork == .product,let product {
                Image(nsImage: product).resizable().interpolation(.high).scaledToFit()
                    .scaleEffect(gpu ? 1.285 : 1) // Compensate for the supplied badge’s white outer margin.
            } else if let chip {
                ZStack {
                    Image(nsImage: chip).resizable().interpolation(.high).scaledToFit()
                    if gpu && vendor == "nvidia",let logo = Self.images["nvidia-logo"] {
                        // The blank die is centered at (0.49,0.486) in the
                        // square source. Scale the complete composition together.
                        Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                            .frame(width: 51.15,height: 23.1).offset(x: -1.155,y: -1.65)
                    }
                }.scaleEffect(1.18)
            } else {
                Image(systemName: gpu ? "pc" : "cpu").resizable().scaledToFit().foregroundStyle(.secondary).padding(8)
            }
        }.frame(width: 105.6,height: 105.6).clipped().accessibilityHidden(true)
    }
}

struct TemperatureCard: View {
    @ObservedObject var model: ControlModel
    let gpu: Bool
    @State private var expanded = false
    var readings: [SensorReading] { model.snapshot.sensors.filter { $0.unit == "°C" && $0.key.hasPrefix(gpu ? "TG" : "TC") } }
    var body: some View {
        Surface { VStack(alignment: .leading,spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    TemperatureArtwork(gpu: gpu)
                    VStack(alignment: .leading,spacing: 6) {
                        Text(gpu ? "GPU temperature" : "CPU temperature").font(AppType.body).foregroundStyle(.secondary)
                        Text(model.formattedTemperature(model.temperature(gpu: gpu))).font(AppType.reading).monospacedDigit()
                    }; Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(AppType.heading).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(gpu ? "GPU" : "CPU") temperature details").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .popover(isPresented: $expanded,arrowEdge: .bottom) {
            VStack(alignment: .leading,spacing: 10) {
                Divider()
                if readings.isEmpty { Text(gpu ? model.snapshot.gpuTemperatureStatus : "No temperature sensor is exposed by the installed drivers.").font(AppType.body).foregroundStyle(.secondary) }
                else {
                    ForEach(readings) { reading in HStack { Text(reading.label); Spacer(); Text(model.formattedTemperature(reading.value)).monospacedDigit() }.font(AppType.body) }
                    Text("Card shows the highest available reading.").font(AppType.body).foregroundStyle(.secondary)
                }
            }.padding(16).frame(width: 290)
            }
            Text(gpu ? Hardware.gpuIdentity.name : Hardware.cpuName)
                .font(AppType.body).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false,vertical: true)
                .frame(maxWidth: .infinity,minHeight: 28,alignment: .topLeading)
                .textSelection(.enabled)
        } }
    }
}
struct ProfilePicker: View {
    @Binding var selection: FanProfile
    var body: some View {
        Picker("Profile",selection: $selection) {
            ForEach(FanProfile.allCases) { profile in Text(profile == .eco ? "Eco · 30%" : profile == .performance ? "Performance · Full" : profile.rawValue).tag(profile) }
        }.labelsHidden().pickerStyle(.segmented)
    }
}
struct FanSliders: View {
    @ObservedObject var model: ControlModel
    var body: some View { VStack(spacing: 8) {
        SpeedSlider(title: "CPU fan",value: $model.settings.cpu)
        SpeedSlider(title: "GPU fan",value: $model.settings.gpu)
    } }
}
struct SpeedSlider: View {
    let title: String
    @Binding var value: Double
    var body: some View { VStack(spacing: 5) {
        HStack { Text(title).font(AppType.body); Spacer(); Text(value == 0 ? "0% · Auto" : "\(Int(value.rounded()))%").font(AppType.heading).monospacedDigit() }
        Slider(value: $value,in: 0...100,step: 1).accessibilityLabel(title)
        HStack { Text("Auto"); Spacer(); Text("Full speed") }.font(AppType.body).foregroundStyle(.secondary)
    } }
}
struct ApplyRow: View {
    @ObservedObject var model: ControlModel
    var body: some View {
        HStack(alignment: .center,spacing: 16) {
            VStack(alignment: .leading,spacing: 3) {
                Text(model.blockReason ?? model.status).font(AppType.body).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true).textSelection(.enabled)
                if !model.hasChanges { Text("Up to date").font(AppType.body).foregroundStyle(accent) }
            }
            Spacer(minLength: 0)
            if model.busy { ProgressView().controlSize(.small) }
            Button("Apply") { model.applyFans() }.buttonStyle(.borderedProminent).disabled(!model.canApply).keyboardShortcut(.return,modifiers: [])
        }
    }
}
struct CurveEditor: View {
    @ObservedObject var model: ControlModel
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text("When the hotter chip reaches…"); Spacer(); Text("Fan request") }.font(AppType.body).foregroundStyle(.secondary)
            ForEach(model.settings.points.indices,id: \.self) { i in
                HStack {
                    Text(model.formattedTemperature(Double(model.settings.points[i].temperature))).monospacedDigit().frame(width: 55,alignment: .leading)
                    Slider(value: $model.settings.points[i].percent,in: 0...100,step: 5).disabled(i == 3).accessibilityLabel("Fan percentage at \(model.settings.points[i].temperature) Celsius")
                    Text("\(Int(model.settings.points[i].percent))%").monospacedDigit().frame(width: 40,alignment: .trailing)
                }.font(AppType.body)
            }
            Text(model.settings.valid ? "Speed increases smoothly between these points. 90°C always requests full speed." : "Each point must be at least as fast as the previous point.").font(AppType.body).foregroundStyle(model.settings.valid ? Color.secondary : Color.orange)
        }
    }
}
struct PowerPanel: View {
    @ObservedObject var model: ControlModel
    var body: some View {
        Surface { VStack(alignment: .leading,spacing: 16) {
            Text("Power Profile").font(AppType.heading)
            HStack(alignment: .top,spacing: 26) {
                VStack(alignment: .leading,spacing: 10) {
                    Label("On battery",systemImage: "battery.75percent").font(AppType.heading)
                    if model.powerPolicy?.battery != nil {
                        Toggle("Low Power Mode",isOn: $model.power.batteryLowPower).disabled(model.savingPower || model.loadingPower)
                    } else { Text(model.loadingPower ? "Reading power policy…" : "Low Power Mode unavailable").font(AppType.body).foregroundStyle(.secondary) }
                    Picker("Fan profile",selection: $model.power.batteryProfile) { ForEach(FanProfile.allCases) { Text($0.rawValue).tag($0) } }.disabled(!model.power.followSource || model.savingPower)
                }
                Divider()
                VStack(alignment: .leading,spacing: 10) {
                    Label("Plugged in",systemImage: "powerplug.fill").font(AppType.heading)
                    if model.powerPolicy?.ac != nil {
                        Toggle("Low Power Mode",isOn: $model.power.acLowPower).disabled(model.savingPower || model.loadingPower)
                    } else { Text(model.loadingPower ? "Reading power policy…" : "Low Power Mode unavailable").font(AppType.body).foregroundStyle(.secondary) }
                    Picker("Fan profile",selection: $model.power.acProfile) { ForEach(FanProfile.allCases) { Text($0.rawValue).tag($0) } }.disabled(!model.power.followSource || model.savingPower)
                }
            }.toggleStyle(.switch).controlSize(.small).fixedSize(horizontal: false,vertical: true)
            Toggle("Switch fan profiles when the power source changes",isOn: $model.power.followSource).font(AppType.body).disabled(model.savingPower)
            Text("Fan-profile choices are saved locally. Low Power Mode uses one-time approved power access. Unsupported power sources stay disabled.").font(AppType.body).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
            Text(model.powerMessage).font(AppType.body).foregroundStyle(.secondary).textSelection(.enabled)
            if model.systemPowerChanged && !model.powerHelperReady {
                HStack {
                    Text("Enable power access once in Settings.").font(AppType.body).foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable power access…") { model.enablePowerHelper() }.disabled(model.changingPowerHelper)
                }
                Text(model.powerHelperMessage).font(AppType.body).foregroundStyle(.secondary)
            }
            HStack {
                Label(model.serviceEnabled ? "Background service on" : "Background service off",systemImage: model.serviceEnabled ? "checkmark.circle" : "minus.circle").font(AppType.body).foregroundStyle(.secondary)
                Spacer()
                Button(model.savingPower ? "Applying…" : "Apply") { model.savePower() }.disabled(!model.canSavePower)
            }
        } }.onAppear { model.refreshPowerSettings() }
          .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPowerSettings() }
    }
}
enum MenuLayout {
    static let size = NSSize(width: 268,height: 288)
}
struct MenuPanel: View {
    @ObservedObject var model: ControlModel
    var open: () -> Void
    private var summary: String {
        if !model.bridge.ready { return "Driver unavailable" }
        if model.blockReason != nil { return "Open dashboard for details" }
        if model.busy { return "Applying…" }
        return model.hasChanges ? "Changes not applied" : "\(model.activeLabel) applied"
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack { Text("Omen Control Alpha 1.0V").font(AppType.heading); Spacer(); Image(systemName: model.powerSymbol).foregroundStyle(.secondary).help(model.powerLabel) }
            HStack(spacing:12) { menuReadout("CPU",gpu:false); Spacer(minLength:0); menuReadout("GPU",gpu:true) }
            Divider()
            Picker("Profile",selection:$model.settings.profile) {
                ForEach(FanProfile.allCases) { Text($0 == .eco ? "Eco · 30%" : $0 == .performance ? "Performance · Full" : $0.rawValue).tag($0) }
            }.controlSize(.small)
            VStack(spacing:4) {
                compactSlider("CPU",gpu:false)
                compactSlider("GPU",gpu:true)
            }
            Text("0% = Auto · Firmware minimum applies").font(AppType.body).foregroundStyle(.secondary)
            HStack(spacing:8) {
                Button(action:open) {
                    Text(summary).font(AppType.body).lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.blockReason ?? model.status)
                Spacer(minLength:0)
                Button("Apply") { model.applyFans() }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!model.canApply)
            }
            Spacer(minLength:0)
            Divider()
            HStack {
                Button("Dashboard",action:open).buttonStyle(.link)
                Spacer()
                Button("Settings") { model.openSettings?() }.buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(AppType.body)
        }.padding(12).frame(width:MenuLayout.size.width,height:MenuLayout.size.height,alignment:.topLeading).tint(accent)
    }
    private func compactSlider(_ title:String,gpu:Bool) -> some View {
        let binding = Binding<Double>(get:{
            let targets=model.settings.targets(temperature:model.curveTemperature) ?? (0,0)
            return gpu ? targets.1 : targets.0
        },set:{ value in
            if model.settings.profile != .manual {
                // Preserve the other fan's displayed setting. Editing CPU while
                // Auto is selected must not silently force GPU to an old target.
                let targets=model.settings.targets(temperature:model.curveTemperature) ?? (0,0)
                model.settings.cpu=targets.0; model.settings.gpu=targets.1
            }
            model.settings.profile = .manual
            if gpu { model.settings.gpu=value } else { model.settings.cpu=value }
        })
        return HStack(spacing:6) {
            Text(title).font(AppType.body).frame(width:26,alignment:.leading)
            Slider(value:binding,in:0...100,step:1).controlSize(.mini).accessibilityLabel("\(title) fan target; editing switches to Manual")
            Text(binding.wrappedValue == 0 ? "Auto" : "\(Int(binding.wrappedValue.rounded()))%")
                .font(AppType.body).monospacedDigit().frame(width:34,alignment:.trailing)
        }.frame(height:24)
    }
    private func menuReadout(_ title:String,gpu:Bool) -> some View {
        VStack(alignment:.leading,spacing:2) {
            HStack(spacing:4) {
                Text(title).font(AppType.heading).foregroundStyle(.secondary)
                Text(model.formattedTemperature(model.temperature(gpu:gpu))).font(AppType.body).foregroundStyle(.secondary)
            }
            HStack(alignment:.firstTextBaseline,spacing:3) {
                Text(model.rpm(gpu).map(String.init) ?? "—").font(.system(size:20,weight:.medium,design:.rounded)).monospacedDigit()
                Text("RPM").font(AppType.body).foregroundStyle(.secondary)
            }
        }
    }
}
