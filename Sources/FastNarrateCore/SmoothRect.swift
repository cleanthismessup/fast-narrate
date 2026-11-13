import CoreGraphics
import Foundation

/// A rectangle that glides toward a target with a critically damped spring (no overshoot, no
/// sudden stops). Stepped once per display frame, so motion stays smooth at any refresh rate,
/// and a new target mid-motion keeps the current velocity instead of restarting.
public struct SmoothRect {
    public private(set) var value: CGRect
    public var target: CGRect
    /// Roughly the time to cover most of the distance.
    public var smoothTime: Double
    private var vel: [Double] = [0, 0, 0, 0]

    public init(_ r: CGRect, smoothTime: Double = 0.07) {
        value = r
        target = r
        self.smoothTime = smoothTime
    }

    public var isSettled: Bool {
        abs(value.minX - target.minX) < 0.05 && abs(value.minY - target.minY) < 0.05 &&
            abs(value.width - target.width) < 0.05 && abs(value.height - target.height) < 0.05
    }

    /// Jump straight to `r` with no motion.
    public mutating func snap(to r: CGRect) {
        value = r
        target = r
        vel = [0, 0, 0, 0]
    }

    /// Advances by `dt` seconds. Returns true while still moving.
    @discardableResult
    public mutating func step(_ dt: Double) -> Bool {
        guard dt > 0 else { return !isSettled }
        if isSettled { value = target; vel = [0, 0, 0, 0]; return false }
        let cur = [value.minX, value.minY, value.width, value.height].map(Double.init)
        let tgt = [target.minX, target.minY, target.width, target.height].map(Double.init)
        let omega = 2 / max(0.001, smoothTime)
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        var out = [Double](repeating: 0, count: 4)
        for i in 0..<4 {
            let change = cur[i] - tgt[i]
            let temp = (vel[i] + omega * change) * dt
            vel[i] = (vel[i] - omega * temp) * decay
            out[i] = tgt[i] + (change + temp) * decay
        }
        value = CGRect(x: out[0], y: out[1], width: out[2], height: out[3])
        return true
    }
}
