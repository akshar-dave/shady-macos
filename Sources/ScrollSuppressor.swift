import AppKit

// MARK: - Scroll suppression

/// Swallows scroll events while the shade owns the gesture, so pulling the shade down does not
/// also scroll whatever is underneath.
///
/// An event tap that can drop events is genuinely dangerous — an earlier version of this app
/// froze scrolling system-wide — so this one is built defensively:
///
///  * It runs on its own thread. A tap serviced by the main run loop makes every scroll in every
///    app wait on this app's main thread, so one slow frame freezes input everywhere.
///  * The callback does almost nothing: take an uncontended lock, read two values, return. No
///    allocation, no logging, no dispatch to another thread.
///  * Suppression expires by itself. If a drag somehow never ends, `maxSuppression` puts scrolling
///    back after a moment rather than leaving the machine unusable.
final class ScrollSuppressor {
    /// The longest a single gesture may suppress scrolling.
    private static let maxSuppression: CFTimeInterval = 2.0
    /// How long after a release to keep swallowing momentum, so the flick does not leak through.
    /// Short, and cancelled outright by a new gesture.
    private static let momentumTail: CFTimeInterval = 0.25

    private var lock = os_unfair_lock()
    private var active = false
    private var activatedAt: CFTimeInterval = 0
    private var releasedAt: CFTimeInterval = 0
    private var tap: CFMachPort?
    /// Called from the main thread when the shade takes or gives up the gesture.
    func setActive(_ on: Bool) {
        os_unfair_lock_lock(&lock)
        if on, !active { activatedAt = CACurrentMediaTime() }
        if !on, active { releasedAt = CACurrentMediaTime() }
        active = on
        os_unfair_lock_unlock(&lock)
    }

    private func decide(scrollPhase: Int64, momentum: Int64) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let now = CACurrentMediaTime()

        if active {
            // Safety valve: never suppress indefinitely.
            return now - activatedAt < Self.maxSuppression
        }

        // A new gesture beginning ends the tail immediately: those fingers are scrolling the
        // page, and they should not have to wait out the curtain's animation.
        if scrollPhase == 1 {
            releasedAt = 0
            return false
        }

        // Momentum arriving just after a release belongs to the gesture, not to the page.
        return momentum != 0 && now - releasedAt < Self.momentumTail
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "shade.scrollsuppressor"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ScrollSuppressor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            return me.decide(scrollPhase: phase, momentum: momentum)
                ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DebugLog.write("scroll suppression unavailable (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("scroll suppression installed")
        CFRunLoopRun()
    }
}
