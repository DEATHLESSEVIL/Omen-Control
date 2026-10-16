import Foundation

public struct PowerPolicy: Equatable {
    public var battery: Bool?
    public var ac: Bool?
    public init(battery: Bool?, ac: Bool?) { self.battery = battery; self.ac = ac }
    public static func parse(_ text: String) -> Self? {
        var source = "", result = Self(battery: nil, ac: nil)
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(":") { source = value; continue }
            let fields = value.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0] == "lowpowermode", fields[1] == "0" || fields[1] == "1" else { continue }
            if source == "Battery Power:" { result.battery = fields[1] == "1" }
            if source == "AC Power:" { result.ac = fields[1] == "1" }
        }
        return result.battery != nil || result.ac != nil ? result : nil
    }
    public func needsChange(_ desired: PowerSettings) -> Bool {
        (battery.map { $0 != desired.batteryLowPower } ?? false) || (ac.map { $0 != desired.acLowPower } ?? false)
    }
}
extension PowerSettings {
    public func sameLocalRequest(as other: Self) -> Bool {
        followSource == other.followSource && (!followSource || (batteryProfile == other.batteryProfile && acProfile == other.acProfile))
    }
}
