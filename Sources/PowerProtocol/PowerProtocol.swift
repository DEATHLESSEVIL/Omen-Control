import Foundation

// Deliberately exposes no command, path, raw arguments, or arbitrary power keys.
@objc(OmenPowerProtocol) public protocol OmenPowerProtocol {
    func setLowPower(battery: Bool, ac: Bool, changeBattery: Bool, changeAC: Bool,
                     reply: @escaping (Int32, String) -> Void)
}

public enum PowerRequestPolicy {
    public static func authorized(clientUID: UInt32, consoleUID: UInt32?) -> Bool {
        guard let consoleUID else { return false }
        return consoleUID >= 501 && clientUID == consoleUID
    }
    public static func arguments(battery: Bool, ac: Bool, changeBattery: Bool, changeAC: Bool) -> [String] {
        var result = [String]()
        if changeBattery { result += ["-b", "lowpowermode", battery ? "1" : "0"] }
        if changeAC { result += ["-c", "lowpowermode", ac ? "1" : "0"] }
        return result
    }
}
