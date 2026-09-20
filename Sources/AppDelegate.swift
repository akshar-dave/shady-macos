import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shade = ShadeController()
    private lazy var gestures = GestureMonitor(shade: shade)
    private var statusItem: NSStatusItem?
    /// Every "Open at Login" item built, so a change made in one menu shows in the other.
    private var loginItems: [NSMenuItem] = []

    /// True while the screen is locked, and for a moment after it unlocks or the machine wakes.
    private var screenLocked = false
    private var settlingUntil = Date.distantPast
    private var systemIsBusy: Bool { screenLocked || settlingUntil > Date() }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSLog("Accessibility trusted: \(trusted)")
        DebugLog.write("launched; accessibility trusted=\(trusted)")
        shade.contextMenu = buildMenu(toggleTitle: "Close")
        shade.prepare()
        gestures.start()
        observeSystemEvents()

        registerAsLoginItemOnFirstRun()

        // A Mac with no trackpad - a desktop with only a mouse - can never open the curtain, and
        // so can never reach the curtain's own menu. That machine, and only that machine, gets a
        // menu bar item to open it from.
        if !Trackpad.shared.available {
            DebugLog.write("no multitouch device; gesture unavailable")
            setUpStatusItem()
        }
    }

    /// Get out of the way whenever the system itself takes over.
    ///
    /// Switching spaces, entering Mission Control or activating another app are all the user
    /// asking for something other than the curtain, and a full-screen panel at `.screenSaver`
    /// level that outlives them is obtrusive. These are notifications rather than gesture
    /// detection: the system already knows it changed space, and watching for the finger pattern
    /// that caused it would both duplicate that and guess wrong.
    ///
    /// The wallpaper is re-checked on a space change too, since spaces can carry different
    /// desktop pictures. That check is a single `stat` and re-renders only on a real change.
    ///
    /// Locking the screen is deliberately *not* one of these. A curtain that survives the lock is
    /// the point: unlock and it is still there, rather than your screen being handed back in the
    /// open. Locking also has to be actively defended against, because it moves the session to the
    /// login window's own space and brings another application forward, so both of the rules
    /// below would otherwise fire and dismiss the curtain on the way out.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if !self.systemIsBusy { self.shade.close() }
            self.shade.refreshWallpaperIfNeeded()
        }

        // Another app coming forward, but not this one: the menu bar item activates Shady itself,
        // and dismissing on that would close the curtain the moment the menu opened it.
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                              object: nil, queue: .main) { [weak self] note in
            guard let self, !self.systemIsBusy else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.shade.close()
        }

        // Track the lock so the two rules above can stand down while it is in progress. The
        // unlock does not clear it immediately: the space change and the app activation that
        // come with returning to the desktop arrive just after, and would dismiss the curtain
        // the instant it became visible again.
        let locked = DistributedNotificationCenter.default()
        locked.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
        }
        locked.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.settlingUntil = Date().addingTimeInterval(1.5)
        }
        for name: NSNotification.Name in [NSWorkspace.willSleepNotification,
                                          NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.settlingUntil = Date().addingTimeInterval(1.5)
            }
        }

        // The desktop picture rotating on a schedule, or being changed outright. The theme
        // matters too: the built-in wallpapers ship separate light and dark cuts.
        for name in ["com.apple.desktop.changed", "AppleInterfaceThemeChangedNotification"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.shade.refreshWallpaperIfNeeded()
            }
        }
    }

    /// The curtain's context menu, and the same menu the fallback status item uses.
    ///
    /// The first item differs between the two: reached from the curtain it can only mean close,
    /// and reached from the status item - which exists only where there is no trackpad - it can
    /// only mean open. Both run `toggle`, which already knows which way it is going.
    private func buildMenu(toggleTitle: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: toggleTitle, action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(.separator())

        // Start at login. The developer install wires this up with a launchd agent instead, so
        // this is for the copy people drag out of the disk image - which has no agent and would
        // otherwise have to be started by hand after every restart.
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItems.append(login)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shady", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A screen with its top band filled: the curtain part way down, which is the app drawn
        // in the shape of the thing it covers. "clock" described what the curtain happens to
        // show rather than what it does.
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "Shady")
        item.button?.toolTip = "Shady — no trackpad found; use this menu to open the shade"
        item.menu = buildMenu(toggleTitle: "Open Shade")
        statusItem = item
    }

    func applicationWillTerminate(_ note: Notification) { gestures.releaseCursor() }

    /// Add itself to the user's background items the first time it runs from /Applications.
    ///
    /// An app with no window and no Dock icon that does not come back after a restart is an app
    /// people lose. Registering makes it a Login Item, which is also what puts it in System
    /// Settings > General > Login Items where it can be found and removed - a background process
    /// people cannot see the existence of is worse than one they did not ask for.
    ///
    /// Only from /Applications, which is where the disk image puts it. A development build lives
    /// in ~/Applications and is started by its own launchd agent; registering that too would give
    /// it two owners. And only once: `registeredLoginItem` means turning it off in the menu stays
    /// off rather than being undone on the next launch.
    private func registerAsLoginItemOnFirstRun() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !defaults.bool(forKey: "registeredLoginItem")
        else { return }
        defaults.set(true, forKey: "registeredLoginItem")
        do {
            try SMAppService.mainApp.register()
            loginItems.forEach { $0.state = .on }
        } catch {
            NSLog("could not register as a login item: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("could not change login item: \(error.localizedDescription)")
        }
        let on: NSControl.StateValue = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItems.forEach { $0.state = on }
    }

    @objc private func toggle() { shade.toggle() }
}
