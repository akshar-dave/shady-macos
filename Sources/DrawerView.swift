import AppKit

// MARK: - The drawer

/// A label that is not there as far as the mouse is concerned.
///
/// A tile's caption and its text preview are `NSTextField`s, and a text field answers a hit test
/// with itself even when it is a plain label that does nothing with the click. That click then
/// stops at the field instead of reaching the tile underneath, so clicking the words in a text
/// tile - which is most of the tile - did nothing at all, while clicking the margin around them
/// copied. The tile is one target; its labels are paint.
private final class Label: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A small round glyph button: the tile's remove badge.
///
/// Drawn rather than an `NSButton`, because every stock button style brings a bezel, a highlight
/// and a focus ring that all have to be turned off again, and what is wanted here is a circle
/// with a symbol in it that gets brighter under the pointer.
final class GlyphButton: NSView {
    private let symbol: String
    private let image = CALayer()
    private var hovering = false { didSet { refresh() } }
    var action: (() -> Void)?

    override var isFlipped: Bool { false }

    init(symbol: String, description: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        image.contentsGravity = .resizeAspect
        image.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(image)
        toolTip = description
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize(for: .mini),
                                                 weight: .bold)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        glyph?.isTemplate = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(hovering ? 0.85 : 0.55).cgColor
        // Tinted by drawing the template symbol into a white image: a layer has no tint colour,
        // and the alternative is a second view just to hold an image well.
        image.contents = glyph?.tinted(NSColor.white.withAlphaComponent(hovering ? 1 : 0.75))
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        image.frame = bounds.insetBy(dx: 3.5, dy: 3.5)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Swallowed, so the click that removes a tile is not also a click that copies it.
    override func mouseDown(with event: NSEvent) { action?() }
}

/// A named `CAFilter` of the given type.
///
/// `CAFilter` is private, like the backdrop blur in `ShadeView` and `MultitouchSupport` in the
/// gesture code, and is handled the same way: looked up by name, and nil if a macOS release
/// ever takes it away - in which case a tile simply arrives without the blur rather than not
/// arriving at all.
private func makeFilter(_ type: String, name: String) -> NSObject? {
    guard let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    let sel = NSSelectorFromString("filterWithType:")
    guard cls.responds(to: sel),
          let f = cls.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
    else { return nil }
    f.setValue(name, forKey: "name")
    f.setValue(true, forKey: "inputNormalizeEdges")
    return f
}

/// One thing in the drawer, drawn as a tile.
///
/// Clicking it puts it back on the clipboard - a single click, not a double, because the drawer
/// is a surface you reach onto rather than a folder you browse. There is nothing else a click on
/// one of these could reasonably mean.
final class DrawerTile: NSView {
    let item: DrawerItem
    var onCopy: ((DrawerItem) -> Void)?
    var onRemove: ((DrawerItem) -> Void)?
    /// Dropped somewhere new. The point is the tile's centre, in the drawer's coordinates.
    var onMove: ((DrawerItem, CGPoint) -> Void)?
    /// The shape the preview turned out to be, once QuickLook has drawn it.
    var onAspect: ((DrawerItem, Double) -> Void)?

    private let well = CALayer()
    private let art = CALayer()
    private let caption = Label(labelWithString: "")
    private let preview = Label(wrappingLabelWithString: "")
    private let close: GlyphButton

    /// Where the follow-through currently has this tile, relative to its real position.
    private var lagOffset: CGPoint = .zero

    override var isFlipped: Bool { false }

    init(item: DrawerItem, store: DrawerStore) {
        self.item = item
        close = GlyphButton(symbol: "xmark", description: "Remove")
        super.init(frame: .zero)
        wantsLayer = true

        // No well behind a picture. An image or a document preview is already a rectangle of
        // content with its own edges, and a tinted box around it is a frame around a photograph
        // that did not ask for one. Text is the exception below: a line of text floating on the
        // wallpaper is not a thing you can pick up, so it is given paper to be written on.
        if item.kind == .text {
            well.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
            well.cornerRadius = 3
            well.cornerCurve = .continuous
        }
        well.masksToBounds = true
        // The one bit of depth kept anywhere: it is what makes a picture sit *on* the drawer
        // rather than be printed on it, and it is what makes the paper look like paper.
        well.shadowColor = NSColor.black.cgColor
        well.shadowOpacity = 0.28
        well.shadowRadius = 5
        well.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(well)

        // Aspect-fit rather than fill. A drawer is for identifying what you put in it, and a
        // cropped thumbnail of a screenshot is exactly the case where the edges are the content.
        // The tile is cut to the media's own shape, so filling it and fitting it come to the
        // same thing for an image. A file icon keeps `resizeAspect`: an icon is a square drawing
        // and stretching it to a document's page proportions would be absurd.
        art.contentsGravity = item.kind == .file ? .resizeAspect : .resizeAspectFill
        art.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        well.addSublayer(art)

        // Filled in when QuickLook comes back. The tile is already on screen by then; a
        // thumbnail appearing a frame later is a great deal better than the curtain waiting on a
        // RAW file being decoded.
        let side = Config.drawerThumbnailSize
        store.thumbnail(for: item, size: CGSize(width: side, height: side)) { [weak self] image in
            guard let self, let image else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.art.contents = image
            CATransaction.commit()
            // A file's proportions are its preview's, and nobody knows them until the preview
            // exists. The tile is already on screen by now, so it changes shape around what it
            // is showing rather than the picture being fitted into the wrong box.
            if image.size.height > 0 {
                self.onAspect?(item, Double(image.size.width / image.size.height))
            }
        }

        // Ink on paper: dark text on the light card, not the white-on-dark of everything else
        // on the curtain. That contrast is the whole trick - it is what says "a note" at a
        // glance, before a single word has been read.
        preview.font = .systemFont(ofSize: Config.drawerPaperFont, weight: .regular)
        preview.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        preview.maximumNumberOfLines = Config.drawerPaperLines
        preview.lineBreakMode = .byTruncatingTail
        // Lines set tight against each other. At this size the font's own leading is most of
        // the card, and what is wanted is the look of a page of writing - which is as much
        // about the density as about the words, since few of them will actually be read.
        if let text = store.text(of: item) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = -1
            paragraph.lineBreakMode = .byTruncatingTail
            preview.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: Config.drawerPaperFont, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
                .paragraphStyle: paragraph,
            ])
        }
        preview.isHidden = item.kind != .text
        addSubview(preview)

        // Only files are captioned. A thumbnail of an image is the image, and a name under it
        // is a label on something that has already said what it is; a document's preview page
        // or a generic type icon has not.
        // Small, not mini. A filename is something you read a word or two of, so it gets the
        // size the system uses for secondary text everywhere else; mini is for things you
        // glance at without reading, like the badge on a control.
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        caption.textColor = NSColor.white.withAlphaComponent(0.82)
        caption.lineBreakMode = .byTruncatingMiddle
        caption.alignment = .center
        caption.stringValue = item.label
        caption.isHidden = item.kind != .file
        addSubview(caption)

        // Hidden until the pointer is on the tile. Seven of these showing at once would be seven
        // things asking to be clicked, on a surface whose whole job is to show you what you put
        // in it.
        close.isHidden = true
        close.action = { [weak self] in guard let self else { return }; self.onRemove?(self.item) }
        addSubview(close)

        toolTip = item.kind == .file ? item.payload : item.label
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the follow-through puts this tile, relative to where it actually is.
    func setLag(_ offset: CGPoint) {
        lagOffset = offset
        applyTransform()
    }

    private func applyTransform() {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(lagOffset.x, lagOffset.y, 0)
        CATransaction.commit()
    }

    /// Under the pointer a tile only casts further - it does not grow.
    ///
    /// Scaling was tried and taken out again. The tiles sit close together on a surface that is
    /// itself still settling from the pull, and something that changes size as the pointer
    /// crosses it makes the whole drawer feel unstable; the shadow alone says "this one" without
    /// anything moving.
    private func setLifted(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.13)
        well.shadowOpacity = lifted ? 0.45 : 0.28
        well.shadowRadius = lifted ? 11 : 5
        well.shadowOffset = CGSize(width: 0, height: lifted ? -4 : -1)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let captionHeight: CGFloat = caption.isHidden ? 0 : ceil(caption.font?.boundingRectForFont.height ?? 12)
        let wellRect = NSRect(x: 1, y: captionHeight + (captionHeight > 0 ? 3 : 1),
                              width: bounds.width - 2,
                              height: max(0, bounds.height - captionHeight - 4))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        well.frame = wellRect
        // The picture fills the tile. There is no box for it to be inset within any more, and
        // an image floating in the middle of empty space reads as a smaller image, not as one
        // with margins.
        art.frame = CGRect(origin: .zero, size: wellRect.size)
        CATransaction.commit()
        // Written from the top of the page, not floated in the middle of it, and close to the
        // edges: every point of margin here is a word that cannot be read.
        let text = wellRect.insetBy(dx: 4, dy: 3)
        let needed = preview.sizeThatFits(NSSize(width: text.width, height: .greatestFiniteMagnitude))
        preview.frame = NSRect(x: text.minX, y: max(text.minY, text.maxY - needed.height),
                               width: text.width, height: min(text.height, needed.height))
        caption.frame = NSRect(x: 2, y: 0, width: bounds.width - 4, height: captionHeight)
        let side: CGFloat = 17
        close.frame = NSRect(x: wellRect.maxX - side + 3, y: wellRect.maxY - side + 3,
                             width: side, height: side)
    }

    /// The tile arriving: it comes into focus as it settles into place.
    ///
    /// Scale and blur together, because either alone is a different gesture. A thing that only
    /// grows is a thing being zoomed; a thing that only sharpens is a photograph developing.
    /// Both at once is something coming to rest at the depth you are looking at, which is what
    /// putting something down looks like.
    ///
    /// The scale is a spring rather than a curve - it is the same physics the curtain settles
    /// with, and this app is consistent about that - while the blur and the fade are eased.
    /// Springing a blur radius would let it overshoot into negative, which is a crash rather
    /// than a bounce.
    func playEntrance() {
        guard let layer else { return }
        let blur = makeFilter("gaussianBlur", name: "entry")
        blur?.setValue(Config.drawerEntranceBlur, forKey: "inputRadius")
        if let blur { layer.filters = [blur] }

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = Config.drawerEntranceScale
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 300
        spring.damping = 24
        spring.duration = spring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18

        CATransaction.begin()
        // The filter is torn off the moment it reaches zero. A blur filter left in place costs
        // an offscreen pass per frame for the rest of the tile's life, in return for blurring
        // by nothing at all.
        CATransaction.setCompletionBlock { [weak self] in self?.layer?.filters = nil }
        if blur != nil {
            let sharpen = CABasicAnimation(keyPath: "filters.entry.inputRadius")
            sharpen.fromValue = Config.drawerEntranceBlur
            sharpen.toValue = 0
            sharpen.duration = 0.28
            sharpen.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.setValue(0, forKeyPath: "filters.entry.inputRadius")
            layer.add(sharpen, forKey: "sharpen")
        }
        layer.add(spring, forKey: "pop")
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        close.isHidden = false
        setLifted(true)
    }

    override func mouseExited(with event: NSEvent) {
        close.isHidden = true
        setLifted(false)
    }

    /// A click copies; a drag moves.
    ///
    /// The two have to share the same button because there is only one thing you can do to a
    /// tile with a mouse, and both are obvious things to try. They are told apart by distance
    /// rather than by time: waiting to see whether a press becomes a drag would put a delay on
    /// every single copy, and a copy is the common case by a wide margin.
    ///
    /// The whole gesture is tracked here rather than through `mouseDragged`, because the drawer
    /// lives in a panel that is not the active application in the usual sense, and a dragged
    /// tile that loses its event stream half way across the drawer is worse than no dragging.
    override func mouseDown(with event: NSEvent) {
        guard let parent = superview else { return }
        let origin = frame.origin
        let start = parent.convert(event.locationInWindow, from: nil)
        var moved = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let here = parent.convert(next.locationInWindow, from: nil)
            let delta = CGPoint(x: here.x - start.x, y: here.y - start.y)
            if !moved, abs(delta.x) < 4, abs(delta.y) < 4 { continue }
            if !moved {
                moved = true
                // Whatever is being moved comes to the top, and stays there: on a desk, the
                // thing you just touched is the thing on top of the pile.
                parent.addSubview(self, positioned: .above, relativeTo: nil)
            }
            setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        }

        if moved {
            onMove?(item, CGPoint(x: frame.midX, y: frame.midY))
        } else {
            onCopy?(item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Remove", action: #selector(removeSelf), keyEquivalent: "")
            .target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeSelf() { onRemove?(item) }
}

/// The drawer itself: an open surface on the curtain that things are put down on.
///
/// Not a grid. Where something sits is where you put it - a pasted thing lands under the
/// pointer, and if that space is taken it goes to the nearest free space rather than to the
/// next cell in some reading order. Nothing snaps, nothing reflows, and two things left an inch
/// apart stay an inch apart. Position is the only thing a surface like this gives you that a
/// list does not, and it is worth more than tidiness: "bottom left, near the screenshot" is how
/// people actually find things again.
///
/// It is the arrangement that is remembered, not the pixels. Positions are stored as fractions
/// of the drawer, so plugging in a monitor moves everything proportionally instead of leaving
/// half of it off the edge.
final class DrawerView: NSView {
    /// One tile's rubber band, simulated where it actually is rather than as an offset.
    ///
    /// The tile has a position and a velocity in the same coordinates as the drawer, and the
    /// band pulls it towards wherever the drawer currently is. What you see is the difference
    /// between the two. This is the change that made it feel attached: an earlier version
    /// computed a displacement from the drawer's *speed*, which meant a tile leaning further
    /// out the faster the drawer went and sitting still whenever the speed happened to be
    /// steady - backwards. A real object tied to a moving thing is displaced by *changes* in
    /// motion. Hold a constant speed and it catches up and rides level; stop, reverse or flick
    /// and it is thrown, which is precisely the moment the eye is looking for it.
    ///
    /// Damping acts on the tile's velocity *relative to the drawer*, not on its velocity in the
    /// world, which is what makes that true: a tile travelling with the drawer feels no drag.
    ///
    /// State is position and velocity only, so interruption needs no handling. Reverse the pull
    /// mid-flight and the anchor simply starts moving the other way against a mass that already
    /// has momentum. There is nothing to cancel, because there is nothing scheduled.
    private struct Lag {
        var position: CGFloat
        var velocity: CGFloat = 0
        var sideways: CGFloat = 0
        var sidewaysVelocity: CGFloat = 0
        /// Per-tile variation, so the drawerful does not move as one rigid sheet.
        let looseness: CGFloat
        let sway: CGFloat

        mutating func step(_ dt: CGFloat, anchor: CGFloat, anchorVelocity: CGFloat) -> Bool {
            let stiffness = Config.drawerFollowStiffness * looseness
            let damping = Config.drawerFollowDamping
            // Sub-stepped at 240Hz. A stiff spring integrated once per display refresh gains
            // energy on a slow frame, which shows up as a tile that will not settle.
            let steps = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
            let h = dt / CGFloat(steps)
            for _ in 0..<steps {
                velocity += (-stiffness * (position - anchor)
                             - damping * (velocity - anchorVelocity)) * h
                position += velocity * h
                // Sideways has no anchor of its own: it is a fraction of the vertical stretch,
                // eased in by its own spring so it lags the swing rather than mirroring it.
                let target = (position - anchor) * sway
                sidewaysVelocity += (-stiffness * (sideways - target) - damping * sidewaysVelocity) * h
                sideways += sidewaysVelocity * h
            }
            return abs(position - anchor) < 0.05
                && abs(velocity - anchorVelocity) < 0.5
                && abs(sideways) < 0.05
        }

        /// What the eye sees: how far the tile is from where the drawer says it should be,
        /// held within the limit so a flick cannot throw it off the surface.
        func offset(from anchor: CGFloat) -> CGPoint {
            let limit = Config.drawerFollowMax
            let stretch = position - anchor
            return CGPoint(x: min(max(sideways, -limit), limit),
                           y: min(max(stretch, -limit), limit))
        }
    }

    private var lags: [UUID: Lag] = [:]
    private var followLink: CADisplayLink?
    private var followTick: CFTimeInterval = 0
    /// Where the drawer is, and how fast it is going - the anchor the bands pull towards.
    ///
    /// The position is exact, taken from the transform the curtain just applied, so the tiles
    /// are hung off the same number the eye is watching and cannot drift out of step with it.
    /// The velocity is a frame-to-frame difference and therefore noisy - one late frame halves
    /// it, the next doubles it - so it goes through the One Euro filter the gesture itself
    /// uses: smoothed hard while the drawer is slow, where jitter is what the eye catches, and
    /// barely at all while it is fast, where lag is. It only feeds the damping term, so a
    /// little smoothing there costs nothing.
    private var anchor: CGFloat?
    private var anchorVelocity: CGFloat = 0
    private var anchorAt: CFTimeInterval = 0
    private var speedFilter = OneEuroFilter(minCutoff: Config.drawerSpeedMinCutoff,
                                            beta: Config.drawerSpeedBeta)

    private let store = DrawerStore()
    private let hint = Label(labelWithString: "")
    private var furniture: [NSView] = []

    var onEscape: (() -> Void)?
    /// Something was taken out of the drawer. Reaching in is the whole errand, so the curtain
    /// goes away and hands you straight back to whatever you were pasting into - and the shade
    /// closing is its own confirmation that the click landed.
    var onPick: (() -> Void)?
    /// Asks the curtain to throw a spotlight on this rectangle, given in window coordinates,
    /// and later to take it away again.
    var onSpotlight: ((NSRect) -> Void)?
    var onSpotlightEnd: (() -> Void)?

    /// Whether the drawer takes *clicks*.
    ///
    /// False until the curtain is fully open. Hit testing works off frames and ignores the
    /// transform that carries the drawer down, so a mid-pull click would otherwise land on tiles
    /// that are not visually there - and swallow the click meant to dismiss the curtain.
    ///
    /// The keyboard is deliberately not gated on this. A tile has to be where you see it before
    /// it can be clicked, but ⌘V has no target to miss: pull the shade and paste in the same
    /// motion and the paste should land, not be dropped for arriving while the curtain was
    /// still travelling.
    var interactive = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // No tray, no shelf rules, no outlines. What makes this read as shelves is the things
        // standing in rows on them and the space between the rows; drawing the furniture as
        // well was drawing the idea twice.

        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.alignment = .center
        addSubview(hint)

        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Clipboard

    /// ⌘V. Reached through the responder chain, so it also covers the Edit menu this app has
    /// no room for.
    @objc func paste(_ sender: Any?) {
        guard store.hasRoom else {
            say("The drawer is full — clear something to make room")
            return
        }
        // Already in the drawer: say so by showing you where it is, rather than by keeping a
        // second copy of it or by refusing with a message.
        if let known = store.existing(matching: NSPasteboard.general) {
            if let tile = furniture.compactMap({ $0 as? DrawerTile })
                .first(where: { $0.item.id == known.id }) {
                onSpotlight?(convert(tile.frame, to: nil))
                holdSpotlight()
            }
            return
        }

        // Sized for the common case before the thing exists: the search only needs to know
        // roughly how much room to look for, and a tile is retired to its real width the
        // moment it is built.
        let spot = placement(near: pointerPosition(),
                             size: NSSize(width: Config.drawerTileWidth,
                                          height: Config.drawerTileHeight))
        if let added = store.add(from: NSPasteboard.general, at: normalize(spot)) {
            rebuild(arriving: added.id)
        } else {
            say("Nothing on the clipboard to keep")
        }
    }

    /// Where the pointer is, in the drawer's own coordinates.
    ///
    /// Read from the window rather than from an event, because a paste is a keystroke and a
    /// keystroke carries no location. Falling back to the middle covers the case where the
    /// pointer is not over the drawer at all - a paste sent from the keyboard while the mouse
    /// sits somewhere else entirely.
    private func pointerPosition() -> CGPoint {
        guard let window else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(local) ? local : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Somewhere to put a new thing: under the pointer if that space is free, and the nearest
    /// free space to it if not.
    ///
    /// Searched as rings spiralling outward from where you asked for it, so "otherwise find a
    /// better place" means the closest place rather than the next place in some reading order.
    /// Nothing snaps to a grid; the drawer is a surface things are put down on, and a thing put
    /// down an inch from another thing stays an inch from it.
    private func placement(near point: CGPoint, size: NSSize) -> CGPoint {
        let step = Config.drawerTileGap
        let taken = furniture.compactMap { ($0 as? DrawerTile)?.frame }

        func free(_ centre: CGPoint) -> Bool {
            let rect = NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                              width: size.width, height: size.height)
            guard field.contains(rect) else { return false }
            return !taken.contains { $0.insetBy(dx: -step, dy: -step).intersects(rect) }
        }

        let wanted = clamp(point)
        if free(wanted) { return wanted }

        var radius = step
        while radius < max(field.width, field.height) {
            // Sixteen samples a ring: fine enough that no gap a tile would fit through is
            // stepped over, coarse enough that this stays a few dozen rectangle tests.
            for i in 0..<16 {
                let angle = Double(i) / 16 * 2 * .pi
                let candidate = CGPoint(x: wanted.x + CGFloat(cos(angle)) * radius,
                                        y: wanted.y + CGFloat(sin(angle)) * radius)
                if free(clamp(candidate)) { return clamp(candidate) }
            }
            radius += step * 2
        }
        // Nowhere free: put it where it was asked for and let it overlap. The drawer is full
        // long before this, so this is the corner case of a display too small for its contents.
        return wanted
    }

    /// The area tiles may occupy: the drawer, less the margin, less half a tile at each edge so
    /// a centre never puts an edge outside.
    private var field: NSRect {
        let size = tileSize
        return bounds
            .insetBy(dx: Config.drawerPadding, dy: Config.drawerPadding)
            .insetBy(dx: size.width / 2, dy: size.height / 2)
    }

    /// The media's own proportions, fitted inside the one box everything shares.
    private func tileSize(for item: DrawerItem) -> NSSize {
        let box = NSSize(width: Config.drawerTileMaxWidth, height: Config.drawerTileHeight)
        let ratio: CGFloat
        switch item.kind {
        case .text: ratio = Config.drawerPaperAspect
        // Square until the preview has been drawn and said otherwise.
        default: ratio = CGFloat(item.aspect ?? 1)
        }
        // Whichever edge hits the box first decides the size; the other comes in short.
        var width = box.width, height = box.width / max(ratio, 0.01)
        if height > box.height {
            height = box.height
            width = box.height * ratio
        }
        width = max(width, Config.drawerTileMinSide)
        height = max(height, Config.drawerTileMinSide)
        // Files carry their name underneath, which is part of the tile but not part of the
        // picture, so it is added on top of the height the media gets.
        let caption: CGFloat = item.kind == .file ? 15 : 0
        return NSSize(width: width.rounded(), height: height.rounded() + caption)
    }

    /// The biggest a tile can be, for the margins and the free-space search.
    private var tileSize: NSSize {
        NSSize(width: Config.drawerTileMaxWidth, height: Config.drawerTileHeight + 15)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let f = field
        guard f.width > 0, f.height > 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: min(max(point.x, f.minX), f.maxX),
                       y: min(max(point.y, f.minY), f.maxY))
    }

    private func normalize(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
    }

    private func denormalize(_ item: DrawerItem) -> CGPoint {
        clamp(CGPoint(x: CGFloat(item.x) * bounds.width, y: CGFloat(item.y) * bounds.height))
    }

    private func copy(_ item: DrawerItem) {
        store.copyToPasteboard(item)
        onPick?()
    }

    private func remove(_ item: DrawerItem) {
        lags[item.id] = nil
        store.remove(item)
        rebuild()
    }

    // MARK: Follow-through

    /// Told, every frame the curtain moves, where it now is.
    ///
    /// The drawer does not animate anything in response; it moves the anchor and lets the bands
    /// work out the rest. That is the whole of the coupling, and it is why a reversal
    /// mid-gesture needs no special case.
    func curtainMoved(to travel: CGFloat) {
        let now = CACurrentMediaTime()
        if let previous = anchor, now > anchorAt {
            let raw = (travel - previous) / CGFloat(now - anchorAt)
            anchorVelocity = CGFloat(speedFilter.filter(Double(raw), at: now))
        }
        anchor = travel
        anchorAt = now
        startFollowing()
    }

    private func startFollowing() {
        if followLink == nil {
            let link = displayLink(target: self, selector: #selector(stepFollow(_:)))
            link.add(to: .main, forMode: .common)
            followLink = link
            followTick = CACurrentMediaTime()
        }
        followLink?.isPaused = false
    }

    @objc private func stepFollow(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = CGFloat(min(max(now - followTick, 1.0 / 240), 1.0 / 30))
        followTick = now

        guard let anchor else { sender.isPaused = true; return }
        // Nothing has been heard for a couple of frames: the drawer has stopped where it is.
        // The anchor stays put and the bands bring the tiles home to it, which is the settle -
        // no separate ending, and no kick from a speed dropped to zero in one step.
        if now - anchorAt > 0.04 { anchorVelocity = 0 }

        var allSettled = true
        for case let tile as DrawerTile in furniture {
            var lag = lags[tile.item.id]
                ?? Lag(position: anchor,
                       looseness: DrawerView.looseness(of: tile.item),
                       sway: DrawerView.sway(of: tile.item))
            let settled = lag.step(dt, anchor: anchor, anchorVelocity: anchorVelocity)
            lags[tile.item.id] = lag
            allSettled = allSettled && settled
            tile.setLag(lag.offset(from: anchor))
        }

        // Everything hanging level below a stationary anchor: park the link. A display link
        // left running is a wakeup at 120Hz for as long as the app lives.
        if allSettled, anchorVelocity == 0 { sender.isPaused = true }
    }

    /// A tile's own weight, derived from its identity rather than drawn at random, so it
    /// behaves the same way every time the drawer is opened - a thing whose weight changes
    /// between glances is not a thing.
    private static func looseness(of item: DrawerItem) -> CGFloat {
        0.96 + CGFloat(abs(item.id.uuidString.hashValue) % 100) / 100 * 0.08
    }

    /// Which way a tile leans, and how far.
    ///
    /// Outward from the middle of the drawer, by how far out it already sits: the pull is
    /// straight down, so the only sideways story that makes sense is things at the edges being
    /// splayed slightly by the yank. It used to be a random direction per tile, which is what
    /// made this read as jitter - random sideways motion has no cause the eye can attribute,
    /// so it is noise by definition, however small.
    private static func sway(of item: DrawerItem) -> CGFloat {
        let fromCentre = CGFloat(item.x - 0.5) * 2
        return min(max(fromCentre, -1), 1) * Config.drawerFollowSway
    }

    // MARK: Holding the spotlight

    private var spotlightWatchdog: Timer?
    private var spotlightRelease: Timer?
    private var spotlightMonitor: Any?

    /// Keeps the spotlight up for as long as ⌘V is held down, then lets it go after a beat.
    ///
    /// Holding a key down repeats it, so the light staying on is simply the repeats continuing
    /// to arrive: each one refreshes a short watchdog, and the key having been let go is the
    /// watchdog running out. That is the only signal that works here - a `keyUp` carrying the
    /// Command modifier is frequently never delivered to the application at all, which is a
    /// well-worn corner of AppKit and not something to build a light switch on. Command being
    /// released *is* delivered, as a flags change, so that ends it early where it can.
    ///
    /// The delay afterwards is deliberate. Letting go and having the curtain snap back
    /// immediately reads as the effect being yanked away; a beat of held light and then the
    /// reveal reads as it finishing what it was saying.
    private func holdSpotlight() {
        spotlightRelease?.invalidate()
        spotlightRelease = nil

        spotlightWatchdog?.invalidate()
        spotlightWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
            [weak self] _ in self?.letSpotlightGo()
        }

        guard spotlightMonitor == nil else { return }
        spotlightMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            let stillHeld = event.modifierFlags.contains(.command) && event.type == .flagsChanged
            if !stillHeld { self.letSpotlightGo() }
            return event
        }
    }

    private func letSpotlightGo() {
        spotlightWatchdog?.invalidate()
        spotlightWatchdog = nil
        if let monitor = spotlightMonitor { NSEvent.removeMonitor(monitor) }
        spotlightMonitor = nil

        guard spotlightRelease == nil else { return }
        spotlightRelease = Timer.scheduledTimer(withTimeInterval: Config.spotlightLingering,
                                                repeats: false) { [weak self] _ in
            self?.spotlightRelease = nil
            self?.onSpotlightEnd?()
        }
    }

    /// The curtain going away takes the spotlight with it, however it went away.
    func endSpotlight() {
        spotlightWatchdog?.invalidate(); spotlightWatchdog = nil
        spotlightRelease?.invalidate(); spotlightRelease = nil
        if let monitor = spotlightMonitor { NSEvent.removeMonitor(monitor) }
        spotlightMonitor = nil
        onSpotlightEnd?()
    }

    private var hintToken = 0

    /// A line of text that says itself and then gets out of the way.
    private func say(_ message: String) {
        hint.stringValue = message
        hint.alphaValue = 1
        hintToken += 1
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.hintToken == token else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4
                self.hint.animator().alphaValue = 0 }
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }  // Escape
        super.keyDown(with: event)
    }

    // MARK: Layout

    /// Tears the shelves down and builds them again.
    ///
    /// Crude, and deliberately so: this runs when something is added or removed, or the display
    /// changes, never while the curtain is moving, and two dozen views is nothing to rebuild. A
    /// view recycling scheme here would be complexity bought with no frames.
    private func rebuild(arriving: UUID? = nil) {
        furniture.forEach { $0.removeFromSuperview() }
        furniture = []
        guard field.width > 0, field.height > 0 else { return }

        // Oldest first, so the newest thing ends up on top of anything it overlaps.
        for item in store.items.reversed() {
            let tile = DrawerTile(item: item, store: store)
            tile.onCopy = { [weak self] in self?.copy($0) }
            tile.onRemove = { [weak self] in self?.remove($0) }
            tile.onMove = { [weak self] item, centre in
                guard let self else { return }
                let settled = self.clamp(centre)
                tile.setFrameOrigin(NSPoint(x: settled.x - tile.frame.width / 2,
                                            y: settled.y - tile.frame.height / 2))
                self.store.move(item, to: self.normalize(settled))
            }
            tile.onAspect = { [weak self, weak tile] item, aspect in
                guard let self, let tile else { return }
                self.store.noteAspect(aspect, for: item)
                // Resized about its own centre, so a tile that learns its shape grows sideways
                // where it stands instead of jumping.
                let centre = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
                var known = item
                known.aspect = aspect
                let size = self.tileSize(for: known)
                tile.frame = NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                    width: size.width, height: size.height)
            }
            let centre = denormalize(item)
            let size = tileSize(for: item)
            tile.frame = NSRect(x: centre.x - size.width / 2,
                                y: centre.y - size.height / 2,
                                width: size.width, height: size.height)
            addSubview(tile)
            furniture.append(tile)
            // Only the tile that just arrived. Everything else is already where it was; the
            // rebuild is an implementation detail and must not look like one.
            if item.id == arriving { tile.playEntrance() }
        }

        hint.alignment = .left
        hint.frame = NSRect(x: Config.drawerPadding, y: 4,
                            width: max(0, bounds.width - Config.drawerPadding * 2 - 40), height: 14)
    }

    override func layout() {
        super.layout()
        rebuild()
    }
}

private extension NSImage {
    /// A template symbol painted in one colour, as a `CGImage` for a layer's contents.
    func tinted(_ color: NSColor) -> CGImage? {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
