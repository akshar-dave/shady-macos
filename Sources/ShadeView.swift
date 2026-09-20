import AppKit

// MARK: - Lock screen view

/// The shade's contents, drawn with CALayers rather than SwiftUI.
///
/// This is a per-frame hot path, so everything expensive is done once up front:
///
///  * the wallpaper is decoded and blurred ahead of time, into two ready CGImages. Applying a
///    live Gaussian blur to a full-screen image every frame is what made the shade feel heavy.
///  * progressive blur is a cross-fade between the sharp and blurred copies, which the GPU does
///    for free, rather than a real blur whose radius changes.
///  * the window never moves. It stays at full screen size and the *contents* are clipped to the
///    revealed height, so dragging costs a couple of layer property writes instead of a window
///    resize per frame.
/// The system font, optionally with tabular figures.
///
/// Not SF Pro Rounded, which this used to use. Comparing the measured proportions of "2:15" on
/// the lock screen against both designs puts the default face closer, and rounded consistently
/// too wide.
///
/// Tabular figures are for the time only. By default the system font's digits are proportional -
/// a `1` is narrower than a `0` - so the width of "11:11" and "10:00" differ and a centred clock
/// slides as the minutes tick over. Every digit gets the same advance instead. The date does not
/// want them: it is mostly letters, and widened digits would only make "20" sit oddly.
private func clockFont(size: CGFloat, weight: NSFont.Weight, tabular: Bool) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard tabular else { return base }
    let descriptor = base.fontDescriptor.addingAttributes([
        .featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]],
    ])
    return NSFont(descriptor: descriptor, size: size) ?? base
}

/// A bare layer host. `ShadeView` needs two siblings in a defined order - the live-screen
/// backdrop underneath, the curtain's layers on top - and sibling *views* have an order that
/// AppKit guarantees, whereas a sublayer added alongside a subview's layer does not.
private final class LayerHostView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The shade's contents: a curtain that slides down as one piece.
///
/// Everything lives in a single container layer holding the wallpaper, the scrim and the clock,
/// and a frame of animation is one write to that layer's transform. Nothing is resized, nothing
/// is re-laid-out and nothing is redrawn — the compositor just moves a layer it already has.
///
/// This replaced a version that clipped a stationary backdrop to the revealed height. That looked
/// like a mask being wiped rather than a curtain being pulled, and it also meant the full-screen
/// backdrop was recomposited on every frame, which is what made it drop frames.
///
/// Everything expensive happens once up front: the wallpaper is decoded and blurred ahead of
/// time into two ready images, and progressive blur is a cross-fade between them rather than a
/// real blur whose radius changes.
final class ShadeView: NSView {
    /// The live screen behind the window, blurred by the window server.
    ///
    /// This is the one part of the curtain that is not painted from a prepared image, because
    /// the thing it shows - your actual desktop - is not known ahead of time. `.behindWindow`
    /// blending is the supported way to get it, and it costs nothing per frame: the window
    /// server is already compositing what is back there.
    ///
    /// It does not slide with the rest of the curtain. It is *revealed*, growing downward from
    /// the top edge, because it is a view of the screen behind and the screen behind does not
    /// move. Only the wallpaper and clock are carried down by the gesture.
    private let backdrop = NSVisualEffectView()

    /// The same thing done properly: a backdrop layer whose Gaussian radius is a number we set
    /// every frame.
    ///
    /// `NSVisualEffectView` cannot do this. Its materials have a fixed radius, so the only knob
    /// is alpha, and fading a frosted material in over the sharp screen does not read as the
    /// screen going out of focus - it reads as haze, with the sharp image ghosting through
    /// underneath. Progressive blur needs the radius itself to move.
    ///
    /// `CABackdropLayer` and `CAFilter` are private, like `MultitouchSupport` elsewhere in this
    /// app, and are handled the same way: looked up by name, and if a macOS release removes them
    /// `blurFilter` is nil and the curtain falls back to the visual effect view above - a worse
    /// effect, but not a broken one.
    private let backdropLayer: CALayer? = ShadeView.makeBackdropLayer()
    private let blurFilter: NSObject? = ShadeView.makeBlurFilter()
    private let saturationFilter: NSObject? = ShadeView.makeFilter("colorSaturate", name: "saturate")
    /// The translucent sheet over the blur. A sibling of the backdrop rather than a child of it,
    /// because a child would be caught by the backdrop's own filters and get blurred too.
    private let backdropTint = CALayer()
    private var usesRealBlur: Bool { backdropLayer != nil && blurFilter != nil }

    private let content = LayerHostView()

    /// Holds the wallpaper, which does *not* travel with the gesture.
    ///
    /// The curtain is two motions, not one. The clock is carried down by the fingers, so it lives
    /// in `container` and is translated. The wallpaper stays pinned to the screen and is
    /// uncovered, so it lives here: this layer's `frame` is the strip the pull has revealed,
    /// while its `bounds` origin is moved by the same amount, which cancels out and leaves the
    /// wallpaper inside sitting still in screen coordinates.
    ///
    /// The header note above argues against exactly this - a clipped stationary backdrop "looked
    /// like a mask being wiped rather than a curtain being pulled". That was written when the
    /// whole curtain was clipped. With the clock still sliding and the live screen blurring
    /// underneath, the motion is carried by those, and a wallpaper that slid too read as a
    /// second, competing layer of travel.
    private let wallpaperClip = CALayer()
    private let container = CALayer()
    private let base = CALayer()
    private let sharp = CALayer()
    private let blurred = CALayer()
    private let scrim = CALayer()
    private let timeLayer = CATextLayer()
    private let dateLayer = CATextLayer()

    private var screenSize: CGSize = .zero
    private var progress: CGFloat = 0
    private var lastBackdropLog: CFTimeInterval = 0
    private var timeFont: NSFont = .systemFont(ofSize: 96)
    private var dateFont: NSFont = .systemFont(ofSize: 22)

    private static func makeBackdropLayer() -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return nil }
        return cls.init()
    }

    /// A `CAFilter` of the given type, named so its inputs can be reached by key path later.
    private static func makeFilter(_ type: String, name: String) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard cls.responds(to: sel),
              let f = cls.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
        else { return nil }
        f.setValue(name, forKey: "name")
        return f
    }

    private static func makeBlurFilter() -> NSObject? {
        guard let f = makeFilter("gaussianBlur", name: "blur") else { return nil }
        // Without this the blur samples transparent black from beyond the layer's edges and the
        // strip fades out along its own borders.
        f.setValue(true, forKey: "inputNormalizeEdges")
        return f
    }

    /// White frosting over a light desktop, black over a dark one - the same split Apple's light
    /// and dark materials make.
    private func tintColor() -> CGColor {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.black : NSColor.white).cgColor
    }

    private func refreshTintColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdropTint.backgroundColor = tintColor()
        CATransaction.commit()
    }

    init(screenSize: CGSize) {
        self.screenSize = screenSize
        super.init(frame: NSRect(origin: .zero, size: screenSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // No mask here: the window is exactly screen-sized, so anything translated above it is
        // already clipped. A mask on a layer with sublayers costs an offscreen pass per frame.
        layer?.masksToBounds = false

        backdrop.blendingMode = .behindWindow
        backdrop.material = .fullScreenUI
        // `.active`, not `.followsWindowActiveState`: the panel never becomes key during a drag,
        // and a backdrop that switches itself off because the window is not frontmost is no
        // backdrop at all.
        backdrop.state = .active
        backdrop.autoresizingMask = []
        backdrop.alphaValue = 0
        backdrop.isHidden = usesRealBlur
        if !usesRealBlur { addSubview(backdrop) }

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.isOpaque = false
        content.frame = NSRect(origin: .zero, size: screenSize)
        addSubview(content)

        if let bl = backdropLayer, let f = blurFilter {
            bl.masksToBounds = true
            // Nothing but the blur. A backdrop layer is not guaranteed to arrive with a clear
            // background, and anything behind the filter shows up as a flat tint over the whole
            // strip rather than as part of the blurred image.
            bl.backgroundColor = NSColor.clear.cgColor
            bl.isOpaque = false
            // Saturate first, then blur. Boosting afterwards would be amplifying colours the
            // averaging has already thrown away.
            if let sat = saturationFilter {
                sat.setValue(Config.backdropSaturation, forKey: "inputAmount")
                bl.filters = [sat, f]
            } else {
                bl.filters = [f]
            }
            content.layer?.addSublayer(bl)

            backdropTint.backgroundColor = tintColor()
            backdropTint.opacity = 0
            content.layer?.addSublayer(backdropTint)
        }
        content.layer?.addSublayer(wallpaperClip)

        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // No background on the container, and no opacity applied to it either. Setting `opacity`
        // on a layer that has sublayers triggers group opacity: Core Animation renders the whole
        // subtree into an offscreen buffer every frame before fading it. The fade is applied to
        // each leaf layer instead, which composites directly.
        container.contentsScale = scale
        wallpaperClip.contentsScale = scale
        wallpaperClip.masksToBounds = true
        wallpaperClip.backgroundColor = NSColor.clear.cgColor
        base.backgroundColor = NSColor.black.cgColor
        wallpaperClip.addSublayer(base)
        for l in [sharp, blurred, scrim] {
            l.contentsGravity = .resizeAspectFill
            l.contentsScale = scale
            l.masksToBounds = true
            wallpaperClip.addSublayer(l)
        }
        blurred.opacity = 0
        scrim.backgroundColor = NSColor.black.cgColor

        timeFont = clockFont(size: screenSize.height * Config.timeSizeFraction,
                             weight: Config.timeWeight, tabular: true)
        dateFont = clockFont(size: screenSize.height * Config.dateSizeFraction,
                             weight: Config.dateWeight, tabular: false)
        style(timeLayer, font: timeFont, scale: scale)
        style(dateLayer, font: dateFont, scale: scale)
        container.addSublayer(dateLayer)
        container.addSublayer(timeLayer)

        content.layer?.addSublayer(container)
        layout(for: screenSize)
        setProgress(0)
        observeClockPreferences()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in self?.refreshTintColor() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func style(_ l: CATextLayer, font: NSFont, scale: CGFloat) {
        l.font = font
        l.fontSize = font.pointSize
        l.foregroundColor = NSColor.white.cgColor
        l.alignmentMode = .center
        l.contentsScale = scale
        // A very soft shadow only, for legibility on pale wallpaper; the lock screen has no
        // visible drop shadow on the clock.
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.18
        l.shadowRadius = 18
        l.shadowOffset = .zero
        // The text changes once a minute but moves every frame, and a shadow is an offscreen
        // pass. Cache it as a bitmap and the movement costs nothing.
        l.shouldRasterize = true
        l.rasterizationScale = scale
    }

    /// Positions everything inside the container. Called only when the geometry changes, never
    /// per frame.
    private func layout(for size: CGSize) {
        let full = CGRect(origin: .zero, size: size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = full
        container.frame = full
        // The clip's own frame and bounds are set per frame in `setProgress`; its children are
        // full-screen and never move.
        wallpaperClip.frame = full
        wallpaperClip.bounds = full
        base.frame = full
        sharp.frame = full
        blurred.frame = full
        scrim.frame = full

        // Placed by *baseline*, not by box. Positioning text by the top or bottom of its frame
        // makes the result depend on the string - "Sunday" has no descender and "Monday" does, so
        // the date would shift vertically from one day to the next. The baseline is the one line
        // that stays put, and it is what was measured off the lock screen.
        //
        // Layer geometry has its origin at the bottom left, while a single-line `CATextLayer`
        // lays its text out from the top of its bounds, so the baseline sits `ascent` below the
        // frame's upper edge.
        func place(_ layer: CATextLayer, font: NSFont, baselineFromTop: CGFloat) {
            let ascent = ceil(font.ascender), descent = ceil(-font.descender)
            let height = ascent + descent
            let maxY = size.height - baselineFromTop + ascent
            layer.frame = CGRect(x: 0, y: maxY - height, width: size.width, height: height)
        }
        place(timeLayer, font: timeFont, baselineFromTop: size.height * Config.timeBaselineFraction)
        place(dateLayer, font: dateFont, baselineFromTop: size.height * Config.dateBaselineFraction)
        CATransaction.commit()
    }

    func setWallpaper(sharp sharpImage: CGImage?, blurred blurredImage: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sharp.contents = sharpImage
        blurred.contents = blurredImage
        CATransaction.commit()
    }

    func setScreenSize(_ size: CGSize) {
        screenSize = size
        frame = NSRect(origin: .zero, size: size)
        backdrop.frame = NSRect(origin: .zero, size: size)
        backdropLayer?.frame = NSRect(origin: .zero, size: size)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        timeFont = clockFont(size: size.height * Config.timeSizeFraction,
                             weight: Config.timeWeight, tabular: true)
        dateFont = clockFont(size: size.height * Config.dateSizeFraction,
                             weight: Config.dateWeight, tabular: false)
        style(timeLayer, font: timeFont, scale: scale)
        style(dateLayer, font: dateFont, scale: scale)
        layout(for: size)
        setProgress(progress)
    }

    /// Built once and rebuilt only when the system's date preferences change. These were being
    /// constructed on every tick, which is a surprisingly expensive object to allocate once a
    /// second for two strings that change once a minute.
    private var timeFormatter = ShadeView.makeTimeFormatter()
    private var dateFormatter = ShadeView.makeDateFormatter()

    /// The user's actual clock settings, read from where macOS keeps them.
    ///
    /// There is no public API for any of this, but there is something better than guessing: the
    /// menu bar clock stores the pattern it renders, and that pattern is the direct product of
    /// every choice in Control Centre's Clock Options. Parsing it is how you follow "24-hour
    /// time" and "Show seconds" exactly rather than approximating them.
    ///
    /// The explicit overrides in `NSGlobalDomain` win where they are set, because Language &
    /// Region's own 24-hour switch writes there and is what the menu bar itself defers to.
    /// Failing both, the locale's `j` template - "hour, however this user writes it" - is the
    /// documented fallback.
    private enum SystemClock {
        private static var menuBarPattern: String? {
            UserDefaults(suiteName: "com.apple.menuextra.clock")?.string(forKey: "DateFormat")
        }

        static var uses24Hour: Bool {
            let global = UserDefaults.standard
            if global.object(forKey: "AppleICUForce24HourTime") != nil {
                return global.bool(forKey: "AppleICUForce24HourTime")
            }
            if global.object(forKey: "AppleICUForce12HourTime") != nil {
                return !global.bool(forKey: "AppleICUForce12HourTime")
            }
            // In a CLDR pattern `H` is the 24-hour hour and `h` the 12-hour one. Quoted literals
            // could contain either letter, so they are stripped before looking.
            if let p = menuBarPattern?.replacingOccurrences(
                of: "'[^']*'", with: "", options: .regularExpression) {
                if p.contains("H") { return true }
                if p.contains("h") { return false }
            }
            return !(DateFormatter
                .dateFormat(fromTemplate: "j", options: 0, locale: .current)?
                .contains("a") ?? false)
        }

        /// "Show seconds" in Clock Options, which lands in the pattern as `ss`.
        static var showsSeconds: Bool {
            if let p = menuBarPattern, p.contains("ss") { return true }
            return UserDefaults(suiteName: "com.apple.menuextra.clock")?
                .bool(forKey: "ShowSeconds") ?? false
        }
    }

    /// The system's own 12/24-hour choice.
    ///
    /// `j` is the template symbol that means "hour, however this user writes it", so asking the
    /// locale to resolve it is how you read the Language & Region setting - there is no public
    /// API for the toggle itself. The resolved pattern is only inspected for `a` (a day period),
    /// not used directly: locale patterns often zero-pad the hour and the system clock never
    /// shows "08:05". `h` and `H` are the unpadded forms; `hh` and `HH` are the padded ones.
    ///
    /// No AM/PM is appended even in 12-hour mode, matching the lock screen rather than the menu
    /// bar.
    private static func makeTimeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        // `h` and `H` are the unpadded forms; `hh` and `HH` pad to two digits and the system
        // clock never shows "08:05". No day period is appended even in 12-hour mode: the lock
        // screen omits it, and this is a lock screen clock rather than a menu bar one.
        var pattern = SystemClock.uses24Hour ? "H:mm" : "h:mm"
        if SystemClock.showsSeconds { pattern += ":ss" }
        f.dateFormat = pattern
        return f
    }

    private static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }

    /// Toggling 12/24-hour, or changing region, must be picked up by a long-running menu bar app.
    /// `AppleDatePreferencesChangedNotification` is the distributed notification the system posts
    /// for the former; the locale notification covers the latter.
    private func observeClockPreferences() {
        let reload: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.timeFormatter = ShadeView.makeTimeFormatter()
            self.dateFormatter = ShadeView.makeDateFormatter()
            self.updateClock(Date())
        }
        for name in ["AppleDatePreferencesChangedNotification",
                     "com.apple.menuextra.clock.preferences.changed"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main, using: reload)
        }
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil, queue: .main, using: reload)
    }

    /// The time, with the gap around the colon closed up.
    ///
    /// Tabular figures give every digit the same advance width, which is what stops the clock
    /// sliding as the minutes change - but the colon is a narrow glyph that gets no such
    /// treatment, so a wide digit box next to a narrow colon leaves a visible hole on each side
    /// of it. Kerning is applied either side of the colon to take that back out.
    ///
    /// `kern` applies *after* the character it is set on, so closing both sides means setting it
    /// on the character before the colon as well as on the colon itself.
    private func attributedTime(_ text: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [
            .font: timeFont,
            .foregroundColor: NSColor.white,
        ])
        let kern = -timeFont.pointSize * Config.clockColonTightening
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == ":" {
            if i > 0 { a.addAttribute(.kern, value: kern, range: NSRange(location: i - 1, length: 1)) }
            a.addAttribute(.kern, value: kern, range: NSRange(location: i, length: 1))
        }
        return a
    }

    func updateClock(_ date: Date) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        timeLayer.string = attributedTime(timeFormatter.string(from: date))
        dateLayer.string = dateFormatter.string(from: date)
        CATransaction.commit()
    }

    /// One frame of the curtain. `p` is 0...1, a little beyond 1 while rubber banding.
    func setProgress(_ p: CGFloat) {
        progress = p
        let clamped = min(max(p, 0), 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Stage one: the live screen behind, blurred.
        //
        // Revealed rather than slid - see `backdrop`. Its frame is the strip the curtain has
        // uncovered, measured down from the top edge; layer geometry puts the origin at the
        // bottom left, so that strip starts at `height - revealed`.
        //
        // The blur *radius* is fixed by the material and cannot be animated, so the ramp is on
        // alpha instead. Fading a blurred backdrop in over the sharp screen reads as the screen
        // going progressively out of focus, which is the intent; a genuinely widening radius
        // would need a live full-screen Gaussian every frame, which is the cost this whole view
        // is built to avoid.
        let revealed = Double(clamped) * Double(screenSize.height)
        let strip = CGRect(x: 0, y: screenSize.height - CGFloat(revealed),
                           width: screenSize.width, height: CGFloat(revealed))
        let ramp01 = min(1, Double(clamped) / Config.backdropRampEnd)
        let blurRadius = Config.minBackdropBlur
            + (Config.maxBackdropBlur - Config.minBackdropBlur) * ramp01

        if let bl = backdropLayer, usesRealBlur {
            bl.frame = strip
            // The one number that matters: a real radius, growing with the pull. No alpha ramp -
            // the layer is fully present from the first pixel and it is the *focus* that changes.
            bl.setValue(blurRadius, forKeyPath: "filters.blur.inputRadius")
            bl.isHidden = clamped <= 0

            // The tint rides the same ramp as the radius, so the material builds as one thing
            // rather than arriving before the blur it belongs to.
            let tint = Config.backdropTintOpacity * ramp01
            backdropTint.frame = strip
            backdropTint.opacity = Float(tint)
            backdropTint.isHidden = tint < 0.004
        } else {
            backdrop.frame = strip
            backdrop.alphaValue = CGFloat(ramp01)
            backdrop.isHidden = clamped <= 0
        }

        if DebugLog.enabled, clamped > 0, CACurrentMediaTime() - lastBackdropLog > 0.25 {
            lastBackdropLog = CACurrentMediaTime()
            DebugLog.write(String(format:
                "backdrop p=%.2f real=%@ frame=%.0fx%.0f@%.0f radius=%.1f winOpaque=%@ level=%d",
                clamped, usesRealBlur ? "y" : "n", strip.width, strip.height, strip.origin.y,
                blurRadius,
                (window?.isOpaque ?? false) ? "y" : "n", window?.level.rawValue ?? -1))
        }

        // Past fully open the curtain has nothing left to reveal, so the overshoot shows up as
        // the clock continuing to travel. `ShadeController.setProgress` has already damped it,
        // so this is a small movement that springs back the moment the fingers lift.
        let overshoot = max(0, p - 1) * screenSize.height

        // The clock slides down from above; the wallpaper does not.
        container.transform = CATransform3DMakeTranslation(
            0, (1 - clamped) * screenSize.height - overshoot, 0)

        // Uncover the wallpaper. Moving `frame` and `bounds.origin` together means the layer
        // occupies the revealed strip on screen while its contents keep the coordinates they
        // already had, so nothing inside shifts by a pixel as the strip grows.
        wallpaperClip.frame = strip
        wallpaperClip.bounds = CGRect(origin: CGPoint(x: 0, y: screenSize.height - CGFloat(revealed)),
                                      size: strip.size)
        wallpaperClip.isHidden = clamped <= 0

        // The clock belongs to the curtain from the start: it rides down over the blurred
        // desktop, before there is any wallpaper for it to sit on.
        let ramp = min(1, Double(clamped) / Config.opacityRampEnd)
        let fade = Config.minOpacity + (1 - Config.minOpacity) * ramp
        timeLayer.opacity = Float(fade)
        dateLayer.opacity = Float(fade)

        // Stage two: the carried wallpaper takes over, from `wallpaperFadeStart` to fully open.
        let span = max(0.001, Config.wallpaperFadeEnd - Config.wallpaperFadeStart)
        let w = min(1, max(0, (Double(clamped) - Config.wallpaperFadeStart) / span))

        sharp.opacity = Float(w)
        sharp.isHidden = w < 0.004

        // The wallpaper arrives soft and sharpens as it comes, across the *whole* reveal.
        //
        // Sharpening over a late window instead put a hump in the blur. `blurred` is the product
        // of two ramps - the reveal `w` rising and the sharpening falling - so when the falling
        // one started late, the product rose to a peak where they crossed and fell afterwards.
        // The wallpaper visibly blurred and then unblurred again on the way down. Sharpening from
        // the moment the wallpaper appears makes the product monotonic, which is the only thing
        // that guarantees focus moves in one direction.
        let sharpenSpan = max(0.001, 1 - Config.wallpaperFadeStart)
        let resolve = min(1, max(0, (Double(clamped) - Config.wallpaperFadeStart) / sharpenSpan))
        let blurAmount = w * (1 - resolve)
        blurred.opacity = Float(blurAmount)
        // A fully transparent layer still costs compositing time unless it is hidden outright.
        blurred.isHidden = blurAmount < 0.004

        // `base` is the opaque black the wallpaper sits on, and it is pure insurance against an
        // image that fails to cover. It cannot follow `w`: half-black through the middle of the
        // reveal would darken the backdrop, which is the one thing that stage exists to show. It
        // arrives over the last stretch of the reveal, by which point the wallpaper above it is
        // near enough opaque to hide it anyway.
        let solid = min(1, max(0, (w - 0.85) / 0.15))
        base.opacity = Float(solid)
        base.isHidden = solid < 0.004

        // The scrim rides with the wallpaper, not with the pull. Anything tied to the pull is
        // tinting the blurred desktop, and the desktop is meant to come through untinted.
        let scrimAmount = w * (Config.minScrim + (Config.maxScrim - Config.minScrim) * Double(clamped))
        scrim.opacity = Float(scrimAmount)
        scrim.isHidden = scrimAmount < 0.004
        CATransaction.commit()
    }
}
