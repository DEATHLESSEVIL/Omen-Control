import Foundation
import CryptoKit
import IOKit
import Darwin

let fm = FileManager.default
let support = URL(fileURLWithPath: "/Library/Application Support/OMEN Control")
let stateDirectory = URL(fileURLWithPath: "/private/var/db/local.omen.control.install")
let acceptedOpenCore = "1569cd1d183c5ee9fda2eced767a4b2efa307e6edfcf2a50109c9657098671ff"
struct InstallError: LocalizedError { let message: String; var errorDescription: String? { message } }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw InstallError(message: message) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func readPlist(_ url: URL) throws -> [String: Any] {
    guard let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else { throw InstallError(message: "Invalid property list: \(url.lastPathComponent)") }
    return p
}
func plistData(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    try require(process.terminationStatus == 0, "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output)")
    return output
}
func manifest(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let base = root.resolvingSymlinksInPath().standardizedFileURL.path
    var enumerationError: Error?
    guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw InstallError(message: "Cannot enumerate EFI.") }
    for case let url as URL in iterator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(values.isSymbolicLink != true, "EFI contains a symbolic link; automatic installation is refused.")
        if values.isRegularFile == true {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            try require(path.hasPrefix(base + "/"), "EFI enumeration escaped its root.")
            result[String(path.dropFirst(base.count + 1))] = digest(try Data(contentsOf: url))
        }
    }
    if let error = enumerationError { throw error }
    return result
}
func verifyBoard() throws {
    var iterator: io_iterator_t = 0
    try require(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &iterator) == KERN_SUCCESS, "Cannot inspect physical board identity.")
    defer { IOObjectRelease(iterator) }
    func property(_ entry: io_registry_entry_t, _ name: String) -> UInt32? {
        guard let data = IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data, data.count == 4 else { return nil }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
    var found = false
    while true {
        let entry = IOIteratorNext(iterator); if entry == 0 { break }
        if property(entry, "subsystem-vendor-id") == 0x103c && property(entry, "subsystem-id") == 0x8c78 { found = true }
        IOObjectRelease(entry)
    }
    try require(found, "Unsupported physical board. This package is restricted to HP subsystem 103C:8C78.")
    let kernel = try run("/usr/bin/uname", ["-r"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let arch = try run("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try require(kernel.hasPrefix("25.") && (Int(kernel.split(separator: ".").dropFirst().first ?? "0") ?? 0) >= 5 && arch == "x86_64", "This first driver package requires Intel macOS with Darwin 25.5 through 25.99 (Tahoe).")
}
func candidate(_ original: Data) throws -> Data {
    guard var config = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
          var kernel = config["Kernel"] as? [String: Any], var add = kernel["Add"] as? [[String: Any]] else { throw InstallError(message: "Kernel/Add is missing or malformed.") }
    let matches = add.indices.filter { (add[$0]["BundlePath"] as? String)?.lowercased() == "omenfanbridge.kext" }
    try require(matches.count <= 1, "Duplicate fan bridge entries; resolve these manually first.")
    let entry: [String: Any] = ["Arch": "x86_64", "BundlePath": "OmenFanBridge.kext", "Comment": "OMEN board 8C78 fan bridge 0.4.0", "Enabled": true, "ExecutablePath": "Contents/MacOS/OmenFanBridge", "MinKernel": "25.5.0", "MaxKernel": "25.99.99", "PlistPath": "Contents/Info.plist"]
    if let index = matches.first { add[index] = entry } else { add.append(entry) }
    kernel["Add"] = add; config["Kernel"] = kernel
    return try plistData(config)
}
func verifyMountedFAT(_ volume: URL) throws {
    var info = statfs()
    try require(statfs(volume.path, &info) == 0, "Cannot inspect the EFI mount.")
    let type = withUnsafePointer(to: &info.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    let mount = withUnsafePointer(to: &info.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
    }
    try require(type == "msdos" && mount == volume.path && info.f_flags & UInt32(MNT_RDONLY) == 0,
                "The target must be an actual writable mounted FAT EFI volume, not an ordinary folder or a read-only mount.")
}
func findEFI() throws -> URL {
    let volumes = try fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)
    let candidates = volumes.map { $0.appendingPathComponent("EFI/OC") }.filter { fm.fileExists(atPath: $0.appendingPathComponent("config.plist").path) && fm.fileExists(atPath: $0.appendingPathComponent("OpenCore.efi").path) }
    try require(candidates.count == 1, "Mount only the intended OpenCore EFI partition. Exactly one mounted EFI/OC is required; found \(candidates.count). No EFI was changed.")
    let oc = candidates[0]
    try verifyMountedFAT(oc.deletingLastPathComponent().deletingLastPathComponent())
    try require(oc.resolvingSymlinksInPath().path == oc.path, "EFI path contains a symbolic link.")
    try require(digest(try Data(contentsOf: oc.appendingPathComponent("OpenCore.efi"))) == acceptedOpenCore, "OpenCore binary does not match the tested 1.0.8 build. This installer refuses to use a mismatched validator. Use the documented manual installation instead.")
    return oc.deletingLastPathComponent()
}
func prepare(validator: String) throws {
    try require(geteuid() == 0, "Installer must run as administrator.")
    try verifyBoard()
    for directory in [support, stateDirectory] {
        if fm.fileExists(atPath: directory.path) {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            try require(directory.resolvingSymlinksInPath().path == directory.path && (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0, "Installer state directory must be owned by root and not writable by other users.")
        }
    }
    let efi = try findEFI(), oc = efi.appendingPathComponent("OC")
    _ = try run(validator, [oc.appendingPathComponent("config.plist").path])
    let original = try Data(contentsOf: oc.appendingPathComponent("config.plist"))
    let planned = try candidate(original)
    try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    let candidateURL = stateDirectory.appendingPathComponent("candidate.plist")
    try planned.write(to: candidateURL, options: .atomic)
    _ = try run(validator, [candidateURL.path])
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
    let backup = support.appendingPathComponent("Backups/working before OMEN package \(stamp)")
    try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.appendingPathComponent("Backups").path)
    let before = try manifest(efi)
    try fm.copyItem(at: efi, to: backup.appendingPathComponent("EFI"))
    try require(try manifest(backup.appendingPathComponent("EFI")) == before, "EFI backup verification failed; nothing was installed.")
    try JSONSerialization.data(withJSONObject: before, options: [.prettyPrinted, .sortedKeys]).write(to: backup.appendingPathComponent("SHA256.json"), options: .atomic)
    try plistData(["efi": efi.path, "backup": backup.path, "before": before, "candidateDigest": digest(planned)]).write(to: stateDirectory.appendingPathComponent("state.plist"), options: .atomic)
    print("Verified full EFI backup: \(backup.path)")
}
func commit(efi: URL, backup: URL, before: [String: String], planned: Data, driver: URL, validator: String, simulateFailure: Bool = false) throws {
    try require(try manifest(efi) == before, "EFI changed after backup; installation stopped.")
    let oc = efi.appendingPathComponent("OC"), config = efi.appendingPathComponent("OC/config.plist")
    let target = oc.appendingPathComponent("Kexts/OmenFanBridge.kext")
    let staged = oc.appendingPathComponent("Kexts/.OmenFanBridge-install-\(UUID().uuidString).kext")
    try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: driver, to: staged)
    defer { try? fm.removeItem(at: staged) }
    let stagedManifest = try manifest(staged), sourceManifest = try manifest(driver)
    try require(stagedManifest == sourceManifest, "Staged driver verification failed: \(stagedManifest) != \(sourceManifest)")
    do {
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staged, to: target)
        try planned.write(to: config, options: .atomic)
        if simulateFailure { throw InstallError(message: "Simulated commit failure") }
        _ = try run(validator, [config.path])
        try require(try Data(contentsOf: config) == planned && manifest(target) == manifest(driver), "Installed driver/config verification failed.")
    } catch {
        let originalError = error
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let prior = backup.appendingPathComponent("EFI/OC/Kexts/OmenFanBridge.kext")
            if fm.fileExists(atPath: prior.path) { try fm.copyItem(at: prior, to: target) }
            try Data(contentsOf: backup.appendingPathComponent("EFI/OC/config.plist")).write(to: config, options: .atomic)
            try require(try manifest(efi) == before, "Rollback verification failed")
        } catch { throw InstallError(message: "EFI rollback failed: \(error.localizedDescription). Recover using \(backup.path) before rebooting.") }
        throw InstallError(message: "EFI update failed and was rolled back: \(originalError.localizedDescription)")
    }
}
func install() throws {
    try require(geteuid() == 0, "Installer must run as administrator.")
    let state = try readPlist(stateDirectory.appendingPathComponent("state.plist"))
    guard let efiPath = state["efi"] as? String, let backupPath = state["backup"] as? String, let before = state["before"] as? [String: String], let plannedHash = state["candidateDigest"] as? String else { throw InstallError(message: "Missing preflight state") }
    let planned = try Data(contentsOf: stateDirectory.appendingPathComponent("candidate.plist"))
    try require(digest(planned) == plannedHash, "Candidate config changed after validation.")
    try verifyBoard()
    try commit(efi: URL(fileURLWithPath: efiPath), backup: URL(fileURLWithPath: backupPath), before: before, planned: planned, driver: support.appendingPathComponent("Driver/OmenFanBridge.kext"), validator: support.appendingPathComponent("Tools/ocvalidate").path)
    print("EFI update verified. Reboot required. Backup: \(backupPath)")
    try? fm.removeItem(at: stateDirectory)
}
func selfTest() throws {
    let root = fm.temporaryDirectory.appendingPathComponent("omen-installer-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    let original = try plistData(["Kernel": ["Add": [["BundlePath": "Other.kext", "Enabled": true]], "Quirks": ["Test": true]], "PlatformInfo": ["Generic": ["SystemSerialNumber": "SYNTHETIC-TEST-ONLY"]]])
    let planned = try candidate(original)
    let old = try PropertyListSerialization.propertyList(from: original, format: nil) as! NSDictionary
    let new = try PropertyListSerialization.propertyList(from: planned, format: nil) as! NSDictionary
    try require(old["PlatformInfo"] as! NSDictionary == new["PlatformInfo"] as! NSDictionary, "Identity changed")
    try require(try candidate(planned) == planned, "Candidate update is not idempotent")
    let efi = root.appendingPathComponent("EFI"), backup = root.appendingPathComponent("backup"), driver = root.appendingPathComponent("new.kext")
    try fm.createDirectory(at: efi.appendingPathComponent("OC/Kexts/OmenFanBridge.kext"), withIntermediateDirectories: true)
    try original.write(to: efi.appendingPathComponent("OC/config.plist"))
    try Data("old driver".utf8).write(to: efi.appendingPathComponent("OC/Kexts/OmenFanBridge.kext/binary"))
    try fm.createDirectory(at: driver, withIntermediateDirectories: true)
    try Data("new driver".utf8).write(to: driver.appendingPathComponent("binary"))
    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    try fm.copyItem(at: efi, to: backup.appendingPathComponent("EFI"))
    let before = try manifest(efi)
    do {
        try commit(efi: efi, backup: backup, before: before, planned: planned, driver: driver, validator: "/usr/bin/true", simulateFailure: true)
        throw InstallError(message: "Expected rollback test to fail")
    } catch { try require(error.localizedDescription.contains("rolled back"), "Unexpected rollback result: \(error)") }
    try require(try manifest(efi) == before, "Rollback changed EFI")
    try commit(efi: efi, backup: backup, before: before, planned: planned, driver: driver, validator: "/usr/bin/true")
    try require(try Data(contentsOf: efi.appendingPathComponent("OC/config.plist")) == planned, "Commit failed")
    do { try commit(efi: efi, backup: backup, before: before, planned: planned, driver: driver, validator: "/usr/bin/true"); throw InstallError(message: "Expected changed EFI rejection") }
    catch { try require(error.localizedDescription.contains("changed after backup"), "Changed EFI was not rejected") }
    var duplicate = try PropertyListSerialization.propertyList(from: planned, format: nil) as! [String: Any]
    var duplicateKernel = duplicate["Kernel"] as! [String: Any]
    var duplicateAdd = duplicateKernel["Add"] as! [[String: Any]]
    duplicateAdd.append(duplicateAdd.last!); duplicateKernel["Add"] = duplicateAdd; duplicate["Kernel"] = duplicateKernel
    do { _ = try candidate(plistData(duplicate)); throw InstallError(message: "Expected duplicate rejection") }
    catch { try require(error.localizedDescription.contains("Duplicate fan bridge"), "Duplicate entry was accepted") }
    try require((new["Kernel"] as! NSDictionary)["Quirks"] as! NSDictionary == (old["Kernel"] as! NSDictionary)["Quirks"] as! NSDictionary, "Unrelated Kernel values changed")
    let symbolic = root.appendingPathComponent("symbolic")
    try fm.createDirectory(at: symbolic, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: symbolic.appendingPathComponent("link"), withDestinationURL: driver)
    do { _ = try manifest(symbolic); throw InstallError(message: "Expected symlink rejection") }
    catch { try require(error.localizedDescription.contains("symbolic link"), "Symlink was not rejected") }
    print("Installer fixture checks passed: identity preservation, idempotency, verified rollback, commit, concurrent-change rejection, duplicate/symlink rejection, unrelated Kernel preservation.")
}
do {
    let args = CommandLine.arguments
    switch args.dropFirst().first {
    case "prepare": try require(args.count == 3, "Usage: prepare /path/to/ocvalidate"); try prepare(validator: args[2])
    case "install": try install()
    case "check": try verifyBoard(); print("Eligible mounted EFI: \(try findEFI().path)")
    case "--self-test": try selfTest()
    default: throw InstallError(message: "Usage: omen-installer check | prepare VALIDATOR | install | --self-test")
    }
} catch { fputs("OMEN installer: \(error.localizedDescription)\n", stderr); exit(1) }
