import Foundation

// MARK: - Input smoothing

/// The One Euro filter: an adaptive low-pass filter for noisy interactive input.
///
/// A finger is never still, and a plain low-pass filter forces a choice between visible jitter
/// and visible lag. This one varies its cutoff with speed: slow movement, where jitter is what
/// the eye notices, is smoothed hard; fast movement, where lag is what the eye notices, is barely
/// smoothed at all.
///
/// Casiez, Roussel & Vogel, CHI 2012.
struct OneEuroFilter {
    /// Cutoff frequency at rest, in Hz. Lower is smoother and laggier.
    var minCutoff: Double
    /// How much the cutoff rises with speed. Higher cuts lag during fast movement.
    var beta: Double
    /// Cutoff for the speed estimate itself.
    var dCutoff: Double

    private var xPrev: Double?
    private var dxPrev: Double = 0
    private var tPrev: Double = 0

    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let previous = xPrev else {
            xPrev = x; tPrev = t
            return x
        }
        let dt = max(t - tPrev, 1.0 / 1000.0)

        let dx = (x - previous) / dt
        let dxHat = smoothingFactor(dCutoff, dt) * dx
            + (1 - smoothingFactor(dCutoff, dt)) * dxPrev

        let cutoff = minCutoff + beta * abs(dxHat)
        let a = smoothingFactor(cutoff, dt)
        let xHat = a * x + (1 - a) * previous

        xPrev = xHat
        dxPrev = dxHat
        tPrev = t
        return xHat
    }

    private func smoothingFactor(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
