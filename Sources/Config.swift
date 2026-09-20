import AppKit

// MARK: - Tunables

enum Config {
    /// How close to the pad's top edge the fingers must first appear, as a fraction of its
    /// height (1.0 = the very top edge). This is finger position on the *trackpad*; the mouse
    /// pointer and the menu bar are irrelevant.
    ///
    /// Deliberately strict — the top 5% of the pad, not the top quarter. The gesture is a swipe
    /// inwards from *beyond* the edge, not "a swipe that happens to start high up", so the top of
    /// the pad is not a reserved zone: fingers placed near the top and then moved down are
    /// ordinary scrolling and must stay that way.
    ///
    /// Position alone decides this. An earlier version also demanded the fingers already be
    /// moving quickly, on the theory that fingers crossing the edge arrive with speed while
    /// placed fingers start from rest. That was true of a flick and false of a slow deliberate
    /// swipe, which it rejected outright.
    static let trackpadTopZone: CGFloat = 0.95

    /// Fingers entering from off the pad land a few milliseconds apart, so the decision to arm
    /// cannot be made on the first frame alone. This is how long the gesture stays eligible
    /// while the rest of the fingers arrive.
    static let armingWindow: TimeInterval = 0.30

    /// Fraction of the trackpad's height that a full open takes. Fingers starting at the top
    /// edge and travelling this far down the pad fully reveal the shade, so the shade follows
    /// the fingers 1:1 in physical terms.
    static let padTravelSpan: CGFloat = 0.80

    /// Fingers must move down at least this much before the drag is treated as intentional,
    /// so resting two fingers at the top does nothing.
    static let engageDistance: CGFloat = 0.012

    /// Minimum number of fingers. Not an exact count: a third finger brushing the pad during a
    /// two-finger swipe should not cancel the gesture.
    static let requiredFingers = 2

    /// How quickly a flick would coast to a stop, as a per-millisecond decay. This is UIKit's
    /// scroll-view deceleration rate, and it is what turns a release into an intent: the shade
    /// goes wherever the gesture was actually heading.
    static let decelerationRate: CGFloat = 0.998

    /// Window over which release velocity is measured, ending at the last trustworthy frame.
    /// Short, because the fastest part of a flick is its final moments — averaging over longer
    /// throws away exactly the speed the gesture was trying to express.
    static let velocityWindow: TimeInterval = 0.05

    /// How much history to keep for that, and for measuring release velocity.
    static let historyWindow: TimeInterval = 0.30

    /// Input smoothing. A lower `smoothingMinCutoff` removes more jitter while the finger is
    /// slow; a higher `smoothingBeta` removes more lag while it is fast.
    static let smoothingMinCutoff: Double = 1.0
    static let smoothingBeta: Double = 1.4

    /// How long without a touch frame before an in-progress drag is assumed to have ended.
    static let frameTimeout: TimeInterval = 0.12

    /// Fastest plausible finger movement, in pad-heights per second. Anything above this is not
    /// a finger moving but the contact patch shifting as fingers land or lift, and following it
    /// makes the shade visibly jerk. A genuinely fast swipe crosses the pad in ~150ms, or about
    /// 7 pad-heights per second.
    static let maxFingerSpeed: CGFloat = 12

    /// Release spring, in SwiftUI's `.spring(response:dampingFraction:)` parameterisation.
    ///
    /// Critically damped, and the spring additionally stops dead on reaching its target. The
    /// shade slides to the edge and stays there; it must not overshoot and rock back, which
    /// reads as the panel bouncing off the edge like a ball.
    static let springResponse: Double = 0.22
    static let springDamping: Double = 1.0

    /// Above this speed (points/second) a flick decides open/closed regardless of position.
        /// Where the projected resting point has to land for the shade to finish open.
    static let settleThreshold: CGFloat = 0.5

    /// Whether to hide the pointer while the gesture runs.
    ///
    /// Off by default. Disconnecting the pointer from the hardware already holds it perfectly
    /// still - measured drift over a full drag is 0.0pt - so hiding it adds nothing but a
    /// disappearing cursor, which is a surprising thing for an app to do to you. Turn it on if
    /// you would rather the pointer got out of the way entirely.
    static let hideCursorDuringGesture = false

    /// Resistance when dragging past fully open. Subtle: a stretch, not a bounce.
    static let rubberBandFactor: CGFloat = 0.12

    /// Clock typography and placement, measured off a macOS lock screen screenshot.
    ///
    /// On a 1680x1050 point display the time's digits occupy an ink box 92.0pt tall sitting on a
    /// baseline 241.5pt from the top, and the date's baseline is 122.5pt from the top. Everything
    /// is stored as a fraction of screen height so the same proportions hold on any display -
    /// which is the only resolution-independent reading available from a single screenshot. If
    /// the lock screen turns out to use a fixed point size instead, this would need a second
    /// measurement on a differently sized display to tell the two apart.
    static let timeSizeFraction: CGFloat = 0.120190
    static let dateSizeFraction: CGFloat = 0.027864
    static let timeBaselineFraction: CGFloat = 0.230000
    static let dateBaselineFraction: CGFloat = 0.116639

    /// Weights. The measurements disagree about these: the width of "2:15" relative to its height
    /// points at `regular`, while stroke thickness points at `bold`. The disagreement is the
    /// shadow macOS draws behind the clock, which thickens the strokes without widening the
    /// glyphs, so the truth sits between them.
    static let timeWeight: NSFont.Weight = .semibold
    static let dateWeight: NSFont.Weight = .semibold

    /// How much of the gap either side of the clock's colon to take back out, as a fraction of
    /// the font size. Tabular figures widen every digit to a common box; the colon is not a digit
    /// and does not widen, so without this it sits in a hole.
    static let clockColonTightening: CGFloat = 0.06

    /// Lock-screen appearance.
    static let maxBlurRadius: CGFloat = 45

    /// The curtain is two things in sequence: first a blur over whatever is actually on screen,
    /// then the wallpaper it carries.
    ///
    /// `backdropRampEnd` is how far down the pull the live-screen blur reaches full strength;
    /// `wallpaperFadeStart` is where the carried wallpaper begins to take over from it. They meet
    /// at halfway by default, so the first half of the gesture blurs your desktop and the second
    /// half replaces it.
    static let backdropRampEnd: Double = 0.5

    /// Blur radius, in points, applied to the live screen behind the curtain. A real Gaussian
    /// radius that grows with the pull, not a fixed blur being faded in.
    ///
    /// The floor is not zero: the curtain's leading edge should already be softening what is
    /// under it the moment it appears. Starting from nothing means the first stretch of the pull
    /// looks like a transparent rectangle with a hard edge rather than a curtain.
    static let minBackdropBlur: Double = 10
    /// Radius reached at `backdropRampEnd`.
    static let maxBackdropBlur: Double = 25

    /// What separates a system "material" from a plain blur.
    ///
    /// A Gaussian averages neighbouring pixels, and averaging colours desaturates them, so a bare
    /// blur of a colourful desktop comes out grey and flat. Apple's materials counter that with a
    /// saturation boost before the blur and a translucent tint after it, which is why they read
    /// as coloured frosted glass rather than fog. Roughly 1.8x is the figure their blurs sit at.
    static let backdropSaturation: Double = 1.8

    /// Strength of the tint laid over the blur at `backdropRampEnd`. Its colour follows the
    /// system appearance: white frosting over a light desktop, black over a dark one.
    static let backdropTintOpacity: Double = 0.18
    static let wallpaperFadeStart: Double = 0.25
    /// Where the wallpaper reaches full opacity. Deliberately short of the bottom: the curtain
    /// should be solid before it finishes travelling, so the last stretch of the pull is the
    /// clock settling into place rather than the wallpaper still arriving.
    static let wallpaperFadeEnd: Double = 0.75


    /// How transparent the curtain is at the instant it appears, and how far down it has to come
    /// before it is fully opaque. A brief lead-in, not a long fade — the curtain spends most of
    /// its travel at full strength.
    static let minOpacity: Double = 0.55
    static let opacityRampEnd: Double = 0.30
    /// Black laid over the wallpaper once it has taken over.
    ///
    /// Zero by default. This used to end at 0.32, which is a third of the way to black and made
    /// the curtain visibly darker than the desktop picture it was showing - the wallpaper should
    /// look like the wallpaper. The clock stays legible without it: it carries its own soft
    /// shadow. Raise these if a pale wallpaper ever swallows the clock.
    static let minScrim: Double = 0.0
    static let maxScrim: Double = 0.0
}
