import AppKit

// MARK: - Gesture watching

/// Drives the shade directly from finger position on the trackpad.
///
/// Scroll events are deliberately *not* used to move the shade. A scroll delta is a damped,
/// accelerated abstraction over finger movement, so mapping it onto screen distance meant half a
/// trackpad of travel produced roughly a third of a screen — the shade lagged well behind the
/// fingers. Multitouch frames give the finger's real normalised position, so the shade can track
/// it exactly: fingers starting at the top edge and travelling `padTravelSpan` down the pad open
/// it fully, wherever the pointer happens to be.
final class GestureMonitor {
    private let shade: ShadeController

    private var dragging = false
    private var armed = false
    private var startY: CGFloat = 0
    private var lastY: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var velocity: CGFloat = 0
    /// Recent (time, progress) samples, used to measure release velocity over a window.
    private var history: [(t: TimeInterval, p: CGFloat)] = []
    private var previousFingers = 0
    private var frameCount = 0
    private var lastFrameAt: TimeInterval = 0
    private var watchdog: Timer?
    private var healTimer: Timer?
    private var seqStart: TimeInterval = 0
    private var seqMaxY: CGFloat = 0
    /// Where the shade was when this drag began; the drag moves it from there.
    private var baseProgress: CGFloat = 0

    private let suppressor = ScrollSuppressor()

    private func log(_ m: String) { DebugLog.write(m) }

    init(shade: ShadeController) { self.shade = shade }

    /// The shade owns the gesture from the moment it arms, not from the moment it starts moving:
    /// the events in between would otherwise leak through and scroll the page.
    private func updateSuppression() {
        let owning = armed || dragging
        suppressor.setActive(owning)
        cursor.setHeld(owning)
    }

    private let cursor = CursorHold()

    /// Released on quit as well as on every normal path, so an exit mid-gesture cannot leave the
    /// pointer hidden or frozen.
    func releaseCursor() { cursor.setHeld(false) }

    func start() {
        // A warp normally suppresses local mouse input for 0.25s afterwards, which would leave
        // the pointer feeling dead every time the curtain was released.
        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0
        }
        suppressor.start()
        Trackpad.shared.onFrame = { [weak self] fingers, y, time in
            self?.handle(fingers: fingers, rawY: y, time: time)
        }
        Trackpad.shared.start()

        // The trackpad does not always report a final zero-finger frame when the hand leaves, and
        // without one the drag never ends: the curtain simply stops wherever it was. This notices
        // that the frames have dried up and releases the gesture.
        let w = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkStalled() }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w

        // The trackpad stops reporting across sleep/wake *and* across a screen lock, which is a
        // separate transition with separate notifications - the login window takes the device and
        // does not give the registration back. All of them are observed.
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.screensDidWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { _ in
                Trackpad.shared.restart(reason: name.rawValue)
            }
        }
        // Screen lock is not a workspace notification; it is a distributed one.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { _ in
            Trackpad.shared.restart(reason: "screenIsUnlocked")
        }

        // And the backstop, for whatever transition turns out to be next.
        let heal = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.armed, !self.dragging else { return }
            Trackpad.shared.healIfQuiet(threshold: 30)
        }
        RunLoop.main.add(heal, forMode: .common)
        healTimer = heal

        // Esc must work although the shade never takes focus.
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.shade.close() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53, self?.shade.isVisible == true { self?.shade.close(); return nil }
            return e
        }
    }

    /// Converts a finger position into shade progress.
    ///
    /// Relative to where the drag began, not absolute. An absolute mapping works only for
    /// opening from nothing: with the shade already down, dragging up produced a negative
    /// progress and slammed it shut instead of following the fingers back up.
    private func progress(for y: CGFloat) -> CGFloat {
        baseProgress + (startY - y) / Config.padTravelSpan
    }

    /// Velocity in progress-per-second, measured over the final `velocityWindow` of the drag.
    private func measureVelocity() -> CGFloat {
        guard let last = history.last else { return 0 }
        guard let first = history.first(where: { $0.t >= last.t - Config.velocityWindow }),
              last.t - first.t > 0.008 else { return 0 }
        return (last.p - first.p) / CGFloat(last.t - first.t)
    }

    /// Ends a drag whose touch frames have stopped arriving.
    private func checkStalled() {
        cursor.expireIfStale()
        guard dragging || armed else { return }
        guard CACurrentMediaTime() - lastFrameAt > Config.frameTimeout else { return }
        log(String(format: "stalled: no touch frames for %.2fs, releasing",
                   CACurrentMediaTime() - lastFrameAt))
        if dragging {
            dragging = false
            release()
        }
        armed = false
        updateSuppression()
    }

    private func release() {
        let v = measureVelocity()
        log(String(format: "release p=%.3f v=%.2f samples=%d",
                   shade.currentProgress, v, history.count))
        shade.endDrag(normalizedVelocity: v)
    }

    private func handle(fingers: Int, rawY: CGFloat, time: TimeInterval) {
        defer { previousFingers = fingers }

        lastFrameAt = CACurrentMediaTime()

        // Already smoothed, per finger, by `Trackpad`. A second filter on the averaged signal
        // used to sit here. It added its own lag without removing anything the first pass had
        // not, and it ran *before* the trust checks below - so a lurch as fingers landed or
        // lifted was thrown away for position, but had already poisoned the filter's `xPrev` and
        // the speed estimate that sets its cutoff, leaving the next several genuine frames
        // smoothed wrongly too.
        let y = rawY

        // Fingers lifted: release the shade to the spring.
        if fingers == 0 {
            if dragging {
                dragging = false
                release()
            }
            armed = false
            updateSuppression()
            return
        }

        // A new touch sequence begins.
        if previousFingers == 0 {
            seqStart = time
            seqMaxY = y
            startY = y
            lastY = y
            lastTime = time
            velocity = 0
            armed = false
            history.removeAll()
            log(String(format: "seq start y=%.3f fingers=%d", y, fingers))
        }

        if !dragging {
            // Track the highest point seen, which is where the fingers crossed the edge.
            seqMaxY = max(seqMaxY, y)

            // Arm at any point during the window, not just on the first frame: swiping in from
            // off the pad means the fingers arrive a few milliseconds apart, and requiring them
            // all to be present immediately threw the gesture away before it began.
            if !armed, fingers >= Config.requiredFingers {
                let elapsed = time - seqStart
                let fromOutside = seqMaxY >= Config.trackpadTopZone
                    && elapsed <= Config.armingWindow

                // Once the shade is showing, a drag anywhere on the pad may move it — but not
                // while it is on its way out. Grabbing a touch during the closing animation
                // meant having to wait for it to finish before the page underneath would
                // scroll again.
                if fromOutside || (shade.isVisible && !shade.isDismissing) {
                    armed = true
                    startY = y
                    baseProgress = shade.currentProgress
                    lastY = y
                    lastTime = time
                    history.removeAll()
                    updateSuppression()
                    log(String(format: "armed startY=%.3f base=%.2f maxY=%.3f after=%.3fs",
                               startY, baseProgress, seqMaxY, elapsed))
                }
            }
        }

        // Be forgiving once a drag is under way: a finger momentarily lifting, or a third
        // brushing the pad, should not abort it.
        if dragging {
            guard fingers > 0 else { return }
        } else {
            guard armed, fingers >= Config.requiredFingers else { return }
        }

        // A frame where the finger count changed is untrustworthy: fingers are landing or
        // lifting and the reported position lurches. Skip it rather than feed it into either
        // the position or the velocity.
        if fingers != previousFingers {
            lastY = y
            lastTime = time
            return
        }

        // Reject physically impossible jumps outright, so the shade never follows one.
        let dt = time - lastTime
        if dt > 0, abs(y - lastY) / CGFloat(dt) > Config.maxFingerSpeed {
            lastY = y
            lastTime = time
            return
        }

        lastY = y
        lastTime = time

        // Velocity over a short window rather than frame to frame, so a single odd frame
        // cannot fake a fling.
        let p = progress(for: y)
        history.append((time, p))
        history.removeAll { time - $0.t > Config.historyWindow }
        velocity = measureVelocity()

        if !dragging {
            // Wait for real intent before taking over. Either direction counts once the shade is
            // showing, since the drag may be closing it.
            let moved = shade.isVisible ? abs(startY - y) : startY - y
            guard moved > Config.engageDistance else { return }
            dragging = true
            updateSuppression()
            shade.beginDrag()
            log(String(format: "drag begin startY=%.3f", startY))
        }

        // Absolute mapping: the shade sits exactly where the fingers are.
        if DebugLog.enabled {
            frameCount += 1
            if frameCount % 10 == 0 {
                log(String(format: "  drag y=%.3f start=%.3f p=%.3f fingers=%d", y, startY, p, fingers))
            }
        }
        shade.setProgress(p)
    }
}
