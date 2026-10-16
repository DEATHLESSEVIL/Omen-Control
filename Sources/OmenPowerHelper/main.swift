import Foundation
import SystemConfiguration
#if canImport(PowerProtocol)
import PowerProtocol
#endif

final class PowerService: NSObject, OmenPowerProtocol {
    private let clientUID: uid_t
    init(clientUID: uid_t) { self.clientUID = clientUID }
    private let queue = DispatchQueue(label: "local.omen.power.operations")
    func setLowPower(battery: Bool, ac: Bool, changeBattery: Bool, changeAC: Bool,
                     reply: @escaping (Int32, String) -> Void) {
        queue.async {
            var consoleUID: uid_t = 0, consoleGID: gid_t = 0
            guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) != nil,
                  PowerRequestPolicy.authorized(clientUID: self.clientUID, consoleUID: consoleUID) else {
                reply(-1, "Power changes require the current local console session."); return
            }
            guard changeBattery || changeAC else { reply(0, "No power changes requested."); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = PowerRequestPolicy.arguments(battery: battery, ac: ac, changeBattery: changeBattery, changeAC: changeAC)
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                reply(process.terminationStatus, String(decoding: data.prefix(4096), as: UTF8.self))
            } catch { reply(-1, error.localizedDescription) }
        }
    }
}
final class PowerListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0, consoleGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) != nil,
              PowerRequestPolicy.authorized(clientUID: connection.effectiveUserIdentifier, consoleUID: consoleUID) else { return false }
        // Only the current local console user can request the two Boolean settings.
        connection.exportedInterface = NSXPCInterface(with: OmenPowerProtocol.self)
        connection.exportedObject = PowerService(clientUID: connection.effectiveUserIdentifier)
        connection.resume(); return true
    }
}
@main struct OmenPowerHelper {
    static func main() {
        guard geteuid() == 0 else {
            fputs("Run this helper through macOS ServiceManagement, not directly.\n", stderr); return
        }
        let delegate = PowerListener()
        let listener = NSXPCListener(machServiceName: "local.omen.power")
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) { RunLoop.current.run() }
    }
}
