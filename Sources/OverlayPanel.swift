import AppKit

// MARK: - Panel

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?
    let shadeView: ShadeView

    init(screen: NSScreen) {
        shadeView = ShadeView(screenSize: screen.frame.size)
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        contentView = shadeView
    }

    /// ⌘V, routed by hand.
    ///
    /// Key equivalents are normally resolved against the main menu, and this app has no menu -
    /// no Dock icon, no menu bar, nothing for AppKit to search. Without this the drawer would
    /// never see a paste.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            shadeView.drawer.paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// An escape hatch: clicking the shade dismisses it even if the gesture misbehaves.
    override func mouseDown(with event: NSEvent) { onClick?() }

    /// The shade is the app's only surface, so its context menu is the app's only menu.
    ///
    /// With no Dock icon and no menu bar item there is otherwise nowhere to quit from, and an
    /// app people cannot quit is one they have to hunt down in Activity Monitor. Right-clicking
    /// the curtain is where a menu is expected, and it costs the curtain no visible chrome.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: shadeView)
    }
}
