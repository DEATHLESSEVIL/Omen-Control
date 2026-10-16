import Foundation

public enum FanAnimation {
    // A fixed ratio preserves relative RPM. Slow motion prevents a repeated
    // multi-blade image from appearing to reverse at display refresh rates.
    public static let slowMotionFactor = 240.0
    public static func revolutionDuration(rpm: Int?) -> Double? {
        guard let rpm, rpm > 0, rpm <= 15_000 else { return nil }
        return 60 * slowMotionFactor / Double(rpm)
    }
}

/// Monotonic, per-fan phase. Telemetry updates change velocity, never angle.
public struct RotorClock {
    public private(set) var angle = 0.0
    private var lastTime: Double?
    private var rpm: Int?
    public init() {}
    public mutating func setRPM(_ value: Int?, at time: Double) {
        advance(to: time)
        rpm = FanAnimation.revolutionDuration(rpm: value) == nil ? nil : value
    }
    public mutating func advance(to time: Double) {
        guard time.isFinite else { return }
        guard let previous = lastTime else { lastTime = time; return }
        guard time >= previous else { return }
        if let duration = FanAnimation.revolutionDuration(rpm: rpm) {
            angle = (angle - (time-previous) * 2 * .pi / duration).truncatingRemainder(dividingBy: 2 * .pi)
        }
        lastTime = time
    }
}
