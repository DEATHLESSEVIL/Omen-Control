import Foundation
import ServiceManagement
#if canImport(PowerProtocol)
import PowerProtocol
#endif

@MainActor enum PowerHelperClient {
    static let service = SMAppService.daemon(plistName: "local.omen.power.plist")
    static var ready: Bool { service.status == .enabled }
    static var description: String {
        switch service.status {
        case .enabled: return "Power access enabled. Changes do not need repeated password prompts."
        case .requiresApproval: return "Approve OMEN Control in System Settings → General → Login Items & Extensions."
        case .notRegistered: return "Enable power access once to change macOS Low Power Mode. Fan profiles do not need it."
        case .notFound: return "The power helper is missing. Reinstall the complete app in Applications."
        @unknown default: return "Power access is unavailable."
        }
    }
    static func enable() throws {
        guard Bundle.main.bundleURL.path == "/Applications/OmenControl.app" else {
            throw NSError(domain: "OmenPower", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install the complete app in /Applications before enabling power access."])
        }
        if service.status != .enabled && service.status != .requiresApproval { try service.register() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    static func disable() async throws { try await service.unregister() }
    static func apply(battery: Bool, ac: Bool, changeBattery: Bool, changeAC: Bool) async throws {
        guard ready else { throw NSError(domain: "OmenPower", code: 2, userInfo: [NSLocalizedDescriptionKey: description]) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: "local.omen.power", options: .privileged)
            let completion = PowerReply(continuation, connection: connection)
            connection.remoteObjectInterface = NSXPCInterface(with: OmenPowerProtocol.self)
            connection.interruptionHandler = { completion.finish("Power service was interrupted. Check the current settings before retrying.") }
            connection.invalidationHandler = { completion.finish("Power service disconnected. Check the current settings before retrying.") }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ completion.finish($0.localizedDescription) }) as? OmenPowerProtocol else {
                completion.finish("Could not connect to the power service."); return
            }
            proxy.setLowPower(battery: battery, ac: ac, changeBattery: changeBattery, changeAC: changeAC) { code, message in
                completion.finish(code == 0 ? nil : (message.isEmpty ? "macOS rejected the power change (\(code))." : message))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                completion.finish("Power request timed out. Its result is uncertain; refresh the current settings before retrying.")
            }
        }
    }
}
private final class PowerReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<Void, Error>, connection: NSXPCConnection) { self.continuation = continuation; self.connection = connection }
    func finish(_ message: String?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil; connection.interruptionHandler = nil; connection.invalidate()
        if let message { pending.resume(throwing: NSError(domain: "OmenPower", code: 3, userInfo: [NSLocalizedDescriptionKey: message])) }
        else { pending.resume() }
    }
}
