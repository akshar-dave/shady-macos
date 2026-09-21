import AppKit

// MARK: - Controller

/// Owns the shade's position as a continuous 0...1 value so the gesture can drive it directly,
/// handing off to a spring when the fingers lift.
final class ShadeController {
    private var panel: OverlayPanel?
    private var screen: NSScreen?
    private var progress: CGFloat = 0
    private var spring: Spring?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var clockTimer: Timer?
    /// Position requested by the gesture, applied on the next frame.
    private var pendingProgress: CGFloat?

    var isVisible: Bool { progress > 0.001 }
    var isOpen: Bool { (spring?.target ?? progress) > 0.5 }
    /// True while the curtain is springing closed. It is still on screen, but the gesture is
    /// finished with it and a new touch belongs to whatever is underneath.
    var isDismissing: Bool { spring?.target == 0 }
    var currentProgress: CGFloat { progress }

    /// Builds the window and renders the wallpaper at launch.
    ///
    /// Doing any of this lazily on the first scroll event cost 100-150px of dead travel before
    /// the shade appeared, so it all happens up front.
    /// The display the curtain should appear on: the one the pointer is sitting on.
    ///
    /// Not `NSScreen.main`, which is the screen holding the key window and therefore moves around
    /// under you, and not the primary display, which would put the curtain on the laptop panel
    /// while you are working on an external monitor. The pointer is where the user's attention
    /// is, and it is also where the trackpad gesture is happening.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Moves the curtain to `s`, rebuilding anything that depends on the display's geometry.
    ///
    /// Everything here is keyed to one screen's size and scale - the panel, the layer layout, the
    /// pre-rendered wallpaper - and none of it was ever revisited after launch, so plugging in a
    /// monitor, changing resolution or opening the lid on a docked machine left the curtain sized
    /// for a display that was no longer there.
    private func adopt(_ s: NSScreen) {
        guard let panel else { return }
        let changed = screen == nil
            || screen!.frame != s.frame
            || screen!.backingScaleFactor != s.backingScaleFactor
        screen = s
        guard changed else { return }
        DebugLog.write("adopting screen \(Int(s.frame.width))x\(Int(s.frame.height)) @\(s.backingScaleFactor)x")
        panel.setFrame(s.frame, display: false)
        panel.shadeView.setScreenSize(s.frame.size)
        // The wallpaper was rendered for the old geometry, and its fingerprint includes the
        // screen, so this re-renders rather than stretching a stale bitmap.
        refreshWallpaperIfNeeded()
    }

    /// The menu shown when the curtain is right-clicked. Set before `prepare()`.
    var contextMenu: NSMenu?

    func prepare() {
        guard let s = targetScreen() else { return }
        screen = s
        let p = OverlayPanel(screen: s)
        p.onClick = { [weak self] in self?.close() }
        p.shadeView.drawer.onEscape = { [weak self] in self?.close() }
        p.shadeView.drawer.onPick = { [weak self] in self?.close() }
        p.contextMenu = contextMenu
        p.setFrame(s.frame, display: false)
        p.shadeView.updateClock(Date())
        p.shadeView.setProgress(0)
        panel = p
        refreshWallpaperIfNeeded()

        // Created once and parked, never per gesture. Building a display link takes a frame or
        // two to start firing, and doing that at the moment the fingers lift put a visible hitch
        // between the drag ending and the spring starting.
        let l = p.shadeView.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.panel?.shadeView.updateClock(Date())
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, let s = self.targetScreen() else { return }
            self.adopt(s)
        }
        DebugLog.write("shade prepared")
    }

    /// Fingerprint of the wallpaper currently rendered, so an unchanged desktop costs nothing.
    private var wallpaperIdentity: String?
    private var wallpaperLoading = false

    /// Re-renders the wallpaper, but only if the picture behind it has actually changed.
    ///
    /// The desktop picture is not fixed for the life of the app: it rotates on a schedule, it
    /// differs per space, and the user can change it. Re-decoding and re-blurring a full-screen
    /// image is far too expensive to do speculatively, so the guard is a single `stat` and the
    /// work happens only when that fingerprint moves. Decoding and blurring themselves are
    /// already off the main thread in `WallpaperRenderer`.
    func refreshWallpaperIfNeeded() {
        guard let s = screen, let panel, !wallpaperLoading else { return }
        // The rendered bitmap depends on more than the file: it is sized to this display, and
        // which file is chosen depends on light/dark for the built-in wallpapers. All three go
        // into the fingerprint, or a docked machine or a theme switch keeps a stale picture.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let identity = [Wallpaper.identity(for: s) ?? "none",
                        "\(Int(s.frame.width))x\(Int(s.frame.height))@\(s.backingScaleFactor)",
                        dark ? "dark" : "light"].joined(separator: "|")
        guard identity != wallpaperIdentity else { return }
        guard let url = Wallpaper.currentURL(for: s) else {
            DebugLog.write("no wallpaper found")
            return
        }
        wallpaperLoading = true
        wallpaperIdentity = identity
        DebugLog.write("wallpaper source: \(url.path)")
        WallpaperRenderer.render(url: url, screen: s.frame.size,
                                 scale: s.backingScaleFactor) { [weak self] sharp, blurred in
            self?.wallpaperLoading = false
            panel.shadeView.setWallpaper(sharp: sharp, blurred: blurred)
            DebugLog.write("wallpaper rendered sharp=\(sharp != nil) blurred=\(blurred != nil)")
        }
    }

    // MARK: Gesture-driven

    func beginDrag() {
        if panel == nil { prepare() }
        // Only while the curtain is away: moving it mid-gesture would be jarring, and the drag
        // is already mapped onto the old geometry.
        if !isVisible, let s = targetScreen() { adopt(s) }
        refreshWallpaperIfNeeded()
        // A new pull owns the curtain: the drawer gives the keyboard back until it settles open
        // again.
        releaseDrawer()
        stopSpring()
        pendingProgress = nil
        show()
    }

    /// Requests a position from the gesture. Applied on the next display refresh rather than
    /// immediately: touch frames arrive on their own schedule, and pushing them straight to the
    /// screen means some refreshes get two updates and others none, which reads as dropped
    /// frames. One update per frame, in step with the display, is smooth.
    func setProgress(_ p: CGFloat) {
        var v = p
        if v > 1 { v = 1 + (v - 1) * Config.rubberBandFactor }
        pendingProgress = max(0, v)
        link?.isPaused = false
    }

    /// Settles the shade according to where the gesture was heading.
    ///
    /// `normalizedVelocity` is in progress units per second, positive downward.
    ///
    /// Rather than comparing position and speed against separate thresholds — which is what made
    /// this feel arbitrary — the release point is *projected* forward: where would a flick with
    /// this velocity coast to if it decelerated naturally? That single number carries the intent.
    /// A hard flick upward near the bottom still projects above the midpoint and closes; a slow
    /// drag released just past halfway stays open. It is the same model UIKit uses to decide
    /// where a scroll view lands, and the same projection Apple describe in "Designing Fluid
    /// Interfaces".
    func endDrag(normalizedVelocity v: CGFloat) {
        let projected = Self.project(progress, velocity: v)
        let opening = projected > Config.settleThreshold
        DebugLog.write(String(format: "settle p=%.3f v=%.2f projected=%.3f -> %@",
                              progress, v, projected, opening ? "open" : "close"))
        settle(to: opening ? 1 : 0, velocity: v)
    }

    /// Where a value moving at `velocity` would come to rest under natural deceleration.
    static func project(_ value: CGFloat, velocity: CGFloat,
                        decelerationRate rate: CGFloat = Config.decelerationRate) -> CGFloat {
        value + velocity * (rate / (1 - rate)) / 1000
    }

    // MARK: Programmatic

    func open()   { beginDrag(); settle(to: 1, velocity: 0) }
    func close()  { guard isVisible else { return }; settle(to: 0, velocity: 0) }
    func toggle() { isOpen ? close() : open() }

    // MARK: Internals

    private func show() {
        guard let p = panel, let s = screen else { return }
        if p.frame != s.frame { p.setFrame(s.frame, display: false) }
        p.shadeView.updateClock(Date())
        p.orderFrontRegardless()
    }

    /// The window stays put; only layer properties change.
    private func apply() {
        guard let p = panel else { return }
        p.shadeView.setProgress(progress)
        if progress > 0.9 { armDrawer() }
        if progress <= 0.001 {
            releaseDrawer()
            p.orderOut(nil)
        }
    }

    /// Hands the keyboard to the drawer.
    ///
    /// The app has to come forward for this. It runs as an accessory with no Dock icon, and a
    /// non-activating panel belonging to an inactive app is shown the keystrokes of whatever is
    /// actually frontmost, not its own. `AppDelegate` already ignores Shady activating itself,
    /// so this does not dismiss the curtain it is focusing.
    ///
    /// Done as soon as the curtain is known to be opening, not when it arrives. A flick down
    /// followed straight away by ⌘V is one gesture as far as the user is concerned, and the
    /// spring takes a couple of hundred milliseconds to settle - long enough that a paste sent
    /// in that window used to go to whatever app was still frontmost.
    private func focusDrawer() {
        guard let p = panel, isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(p.shadeView.drawer)
    }

    /// Lets the drawer take clicks.
    ///
    /// At nine tenths of the way open rather than at the end of the spring. The last tenth is
    /// a few points of travel that the eye has already discounted - by then the drawer is
    /// where it is going to be - and waiting for the spring to formally finish put a beat
    /// between the curtain arriving and it answering the mouse. That beat is felt as the app
    /// being slow, even though nothing was.
    private func armDrawer() {
        panel?.shadeView.drawer.interactive = true
    }

    /// Lets go of the keyboard and the mouse.
    ///
    /// The panel sits at screen-saver level over everything, so a drawer still holding first
    /// responder while the curtain slides away is a view eating the ⌘V meant for the app
    /// underneath. Nothing needs saving here: the drawer writes to disk as things go into it.
    private func releaseDrawer() {
        guard let p = panel else { return }
        p.shadeView.drawer.interactive = false
        p.shadeView.drawer.endSpotlight()
        p.makeFirstResponder(nil)
        p.resignKey()
    }

    private func settle(to target: CGFloat, velocity: CGFloat) {
        if panel == nil { prepare() }
        if target > 0 { show() }
        if target <= 0 { releaseDrawer() } else { focusDrawer() }
        // Drop any position the gesture had queued for the next frame. The spring owns the
        // shade from here; applying a stale touch frame after it finishes would snap the curtain
        // back to wherever the fingers happened to stop.
        pendingProgress = nil
        spring = Spring(value: progress, velocity: velocity, target: target)
        startSpring()
    }

    private func startSpring() {
        lastTick = CACurrentMediaTime()
        link?.isPaused = false
    }

    private func stopSpring() { spring = nil }

    /// One frame of motion, whichever thing is driving it.
    @objc private func tick(_ sender: CADisplayLink) {
        let now = sender.timestamp

        if var sp = spring {
            let dt = CGFloat(min(max(now - lastTick, 1.0 / 240.0), 1.0 / 30.0))
            lastTick = now
            let done = sp.step(dt)
            spring = sp
            progress = sp.value
            apply()
            if done {
                stopSpring()
                if progress > 0.5 { focusDrawer(); armDrawer() }
            }
        } else if let p = pendingProgress {
            pendingProgress = nil
            lastTick = now
            progress = p
            apply()
        } else {
            lastTick = now
            // Nothing to animate; park the link so it costs nothing while idle.
            if progress <= 0.001 { sender.isPaused = true }
        }
    }
}
