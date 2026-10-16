import AppKit
import SwiftUI

/// Native materials follow system appearance and Reduce Transparency settings.
struct TranslucentBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A public AppKit panel gives the menu its actual eight-point outer corners.
@MainActor final class MenuBarWindow: NSPanel {
    private var monitors: [Any] = []
    private weak var anchorWindow: NSWindow?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init<Content: View>(rootView: Content, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: rootView.overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12))
                .allowsHitTesting(false)))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        contentView = effect
        setContentSize(size)
        setAccessibilityLabel("OMEN Control fan controls")
    }

    func present(below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        dismiss()
        anchorWindow = window
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let x = min(max(anchor.midX - frame.width / 2, visible.minX + 4), visible.maxX - frame.width - 4)
        let y = max(visible.minY + 4, anchor.minY - frame.height - 5)
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss(); return nil }
            } else if event.window !== self && event.window !== self.anchorWindow {
                // Native picker menus own a separate popup-level window.
                if let target = event.window, target.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                    self.dismiss()
                }
            }
            return event
        }) { monitors.append(monitor) }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        orderOut(nil)
    }
}
