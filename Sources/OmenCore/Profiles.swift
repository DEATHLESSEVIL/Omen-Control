import Foundation

public enum FanProfile: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto", eco = "Eco", manual = "Manual", performance = "Performance", curve = "Temperature curve"
    public var id: String { rawValue }
    public var explanation: String {
        switch self {
        case .auto: return "Your laptop adjusts both fans automatically."
        case .eco: return "Requests 30% on both fans. The firmware minimum still applies."
        case .manual: return "Choose each fan’s speed. Percentages are requests, not measured speed."
        case .performance: return "Runs both fans at their maximum target."
        case .curve: return "Fan speed follows the hotter CPU or GPU reading. Both temperatures must be available."
        }
    }
}
public struct CurvePoint: Codable, Equatable, Identifiable {
    public var id: Int { temperature }
    public var temperature: Int
    public var percent: Double
    public init(_ temperature: Int, _ percent: Double) { self.temperature = temperature; self.percent = percent }
}
public struct FanSettings: Codable, Equatable {
    public var profile: FanProfile = .auto
    public var cpu: Double = 70
    public var gpu: Double = 70
    public var points = [CurvePoint(45,35), CurvePoint(60,50), CurvePoint(75,75), CurvePoint(90,100)]
    public init() {}
    public var valid: Bool {
        cpu.isFinite && gpu.isFinite && (0...100).contains(cpu) && (0...100).contains(gpu)
        && points.count == 4 && points.allSatisfy { (0...100).contains($0.percent) && $0.percent.isFinite }
        && zip(points,points.dropFirst()).allSatisfy { $0.temperature < $1.temperature && $0.percent <= $1.percent }
        && points.last?.temperature == 90 && points.last?.percent == 100
    }
    // Only settings used by the active profile affect whether Apply is needed.
    public func sameRequest(as other: Self) -> Bool {
        guard profile == other.profile else { return false }
        switch profile {
        case .manual: return cpu.rounded() == other.cpu.rounded() && gpu.rounded() == other.gpu.rounded()
        case .curve: return points == other.points
        default: return true
        }
    }
    public func targets(temperature: Double?) -> (Double,Double)? {
        switch profile {
        case .auto: return (0,0)
        case .eco: return (30,30)
        case .manual: return (cpu.rounded(),gpu.rounded())
        case .performance: return (100,100)
        case .curve:
            guard valid, let t = temperature, t.isFinite else { return nil }
            if t <= Double(points[0].temperature) { return (points[0].percent,points[0].percent) }
            for (a,b) in zip(points,points.dropFirst()) where t <= Double(b.temperature) {
                let ratio = (t-Double(a.temperature))/Double(b.temperature-a.temperature)
                let v = (a.percent+(b.percent-a.percent)*ratio).rounded()
                return (v,v)
            }
            return (100,100)
        }
    }
}
public enum TemperatureUnit: String, CaseIterable, Codable {
    case celsius = "°C", fahrenheit = "°F"
    public func value(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
}
public struct PowerSettings: Codable, Equatable {
    public var batteryLowPower = true
    public var acLowPower = false
    public var followSource = false
    public var batteryProfile: FanProfile = .eco
    public var acProfile: FanProfile = .auto
    public init() {}
}
