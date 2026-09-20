import CoreGraphics

// MARK: - Spring

/// A damped harmonic oscillator, integrated semi-implicitly. Same parameterisation as SwiftUI's
/// `.spring(response:dampingFraction:)`, so it matches the rest of the system.
struct Spring {
    var value: CGFloat
    var velocity: CGFloat
    var target: CGFloat
    private let stiffness: CGFloat
    private let damping: CGFloat

    init(value: CGFloat, velocity: CGFloat = 0, target: CGFloat,
         response: Double = Config.springResponse,
         dampingFraction: Double = Config.springDamping) {
        self.value = value; self.velocity = velocity; self.target = target
        let omega = 2 * Double.pi / response
        self.stiffness = CGFloat(omega * omega)
        self.damping = CGFloat(2 * dampingFraction * omega)
    }

    /// Advances the simulation; returns true once at rest.
    ///
    /// The value is not allowed past its target. A critically damped spring given enough initial
    /// velocity still overshoots once, and at the open or closed limit that overshoot is the
    /// shade visibly bouncing off the edge. Reaching the target ends the animation.
    mutating func step(_ dt: CGFloat) -> Bool {
        let steps = max(1, Int((dt / (1.0 / 240.0)).rounded(.up)))
        let h = dt / CGFloat(steps)
        let startedBelow = value < target

        for _ in 0..<steps {
            let accel = -stiffness * (value - target) - damping * velocity
            velocity += accel * h
            value += velocity * h

            // Crossed the target: settle exactly on it.
            if (startedBelow && value >= target) || (!startedBelow && value <= target) {
                value = target
                velocity = 0
                return true
            }
        }

        if abs(value - target) < 0.0005 && abs(velocity) < 0.01 {
            value = target; velocity = 0; return true
        }
        return false
    }
}
