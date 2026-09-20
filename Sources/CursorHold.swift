import AppKit

// MARK: - Cursor

/// Keeps the pointer still, and out of sight, while the gesture is running.
///
/// Four earlier attempts failed, and the last one is the instructive one. Warping the cursor back
/// on every touch frame *does* control the drawn position, but only after the fact: the window
/// server moves the pointer, and a frame later we drag it back, 120 times a second. The result is
/// exactly what it sounds like - the cursor shivering around its starting point for the length of
/// the gesture. Correcting the position cannot work; the movement has to not happen.
///
/// So this does two things at once, because from an accessory application with a non-activating
/// panel it is genuinely unclear which of them the system will honour:
///
///  * `CGAssociateMouseAndMouseCursorPosition(false)` disconnects the hardware from the cursor,
///    so nothing moves it in the first place. This is the real fix if it takes effect.
///  * the cursor is hidden for the duration. If the disconnect is ignored, the pointer may still
///    wander, but a pointer nobody can see cannot be seen to shiver - and it is put back where it
///    started before it reappears.
///
/// `drift` records which of those actually happened, so the log settles the question rather than
/// another round of guessing.
final class CursorHold {
    private static let maxHold: CFTimeInterval = 2.0

    private var held = false
    private var heldAt: CFTimeInterval = 0
    private var origin = CGPoint.zero

    func setHeld(_ on: Bool) {
        if on {
            guard !held else { return }
            origin = CGEvent(source: nil)?.location ?? .zero
            held = true
            heldAt = CACurrentMediaTime()
            CGAssociateMouseAndMouseCursorPosition(0)
            if Config.hideCursorDuringGesture { CGDisplayHideCursor(CGMainDisplayID()) }
        } else {
            guard held else { return }
            held = false
            let ended = CGEvent(source: nil)?.location ?? origin
            let drift = hypot(ended.x - origin.x, ended.y - origin.y)
            // Put it back before it becomes visible again, so the restore is never seen.
            CGWarpMouseCursorPosition(origin)
            CGAssociateMouseAndMouseCursorPosition(1)
            if Config.hideCursorDuringGesture { CGDisplayShowCursor(CGMainDisplayID()) }
            DebugLog.write(String(format: "cursor released; drift while held = %.1fpt", drift))
        }
    }

    /// Never hold the pointer indefinitely: an invisible, immovable cursor is far worse than a
    /// wandering one. Polled by the gesture watchdog.
    func expireIfStale() {
        guard held, CACurrentMediaTime() - heldAt > Self.maxHold else { return }
        DebugLog.write("cursor hold expired")
        setHeld(false)
    }
}
