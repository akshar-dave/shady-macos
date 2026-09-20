import AppKit

// MARK: - Wallpaper

/// Finds the image macOS is currently using behind the lock screen.
enum Wallpaper {
    /// The file the wallpaper will be loaded from, without loading it.
    ///
    /// Split out so a change can be noticed without decoding anything: `identity` stats this
    /// file, which is what lets the app re-render only when the picture has actually changed.
    static func currentURL(for screen: NSScreen?) -> URL? {
        candidateURLs(screen).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A cheap fingerprint of the current wallpaper: path plus modification date and size.
    ///
    /// A `stat` on one file, which is what makes "keep the wallpaper current" affordable. Nothing
    /// here decodes an image, and nothing polls: this is consulted when the desktop changes and
    /// when the curtain is about to be pulled, not on a timer.
    static func identity(for screen: NSScreen?) -> String? {
        guard let url = currentURL(for: screen),
              let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.path)|\(date)|\(size)"
    }

    private static func candidateURLs(_ screen: NSScreen?) -> [URL] {
        var urls: [URL] = []

        // The wallpaper store, which is the only place that knows what is actually on screen.
        if let u = storedChoice() { urls.append(u) }

        // The public API, which on Sonoma and later frequently reports
        // `/System/Library/CoreServices/DefaultDesktop.heic` - the OS release's stock picture -
        // no matter what the user has chosen. Kept as a fallback, but deliberately behind the
        // store, because a confidently wrong answer is worse than none.
        if let s = screen ?? NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: s) {
            urls.append(u)
        }

        return urls.filter {
            ["jpg", "jpeg", "png", "heic", "tiff", "mov", "mp4"].contains($0.pathExtension.lowercased())
        }
    }

    /// The desktop picture recorded in `com.apple.wallpaper`'s index.
    ///
    /// This used to read the file as UTF-8 text and scrape `file://` URLs out of it with a
    /// regular expression. `Index.plist` is a *binary* plist, so the UTF-8 decode returned nil
    /// every time and the whole branch was dead code - which is how the stock picture ended up on
    /// screen. Parsed as a plist it is perfectly tractable.
    private static func storedChoice() -> URL? {
        let path = ("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist" as NSString)
            .expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let all = root["AllSpacesAndDisplays"] as? [String: Any],
              let desktop = all["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first
        else { return nil }

        // A picture the user chose themselves is listed by file.
        if let files = choice["Files"] as? [Any] {
            for f in files {
                let raw = (f as? String) ?? (f as? [String: Any])?["relative"] as? String
                if let raw, let u = URL(string: raw), FileManager.default.fileExists(atPath: u.path) {
                    return u
                }
            }
        }

        // A built-in wallpaper lists no file at all, only the provider that supplies it, plus a
        // `Configuration` that is itself a nested binary plist.
        if let provider = choice["Provider"] as? String {
            return builtInAsset(provider: provider,
                                configuration: nested(choice["Configuration"]))
        }
        return nil
    }

    private static func nested(_ value: Any?) -> [String: Any] {
        guard let data = value as? Data,
              let d = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return d
    }

    /// An aerial wallpaper, which is keyed by asset id and kept in an entirely different store
    /// from the still pictures.
    ///
    /// The videos come in several encodings; the highest available is used. There is also a
    /// `snapshots/asset-preview-<id>.jpg` beside them, and it is tempting because it is a still -
    /// but it is a 214x130 thumbnail, so it is the last resort rather than the first choice.
    private static func aerialAsset(id: String) -> URL? {
        let fm = FileManager.default
        let root = "/Library/Application Support/com.apple.idleassetsd"
        for quality in ["4KSDR240FPS", "4KSDR", "4KHDR", "2KSDR", "2KHDR", "2KAVC"] {
            let u = URL(fileURLWithPath: "\(root)/Customer/\(quality)/\(id).mov")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let preview = URL(fileURLWithPath: "\(root)/snapshots/asset-preview-\(id).jpg")
        return fm.fileExists(atPath: preview.path) ? preview : nil
    }

    /// Locates a built-in wallpaper's asset from its provider identifier.
    ///
    /// `com.apple.wallpaper.choice.sonoma` means the Sonoma family, whose files sit in
    /// `.wallpapers/Sonoma`. These ship only as `.mov`: the "graphic" wallpapers are animated, and
    /// there is no still beside them to load instead - a frame has to be pulled out of the video.
    private static func builtInAsset(provider: String, configuration: [String: Any]) -> URL? {
        if provider.lowercased().contains("aerial"), let id = configuration["assetID"] as? String {
            return aerialAsset(id: id)
        }
        guard let token = provider.split(separator: ".").last.map(String.init)?.lowercased()
        else { return nil }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers")
        guard let families = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return nil }

        // Exact name first, then the shortest containing match. The families overlap by prefix -
        // "Sonoma" and "Sonoma Horizon" both contain "sonoma" - and directory order is arbitrary,
        // so a plain `contains` picks between them at random.
        let name = { (u: URL) in u.lastPathComponent.lowercased() }
        let family = families.first { name($0) == token }
            ?? families.filter { name($0).contains(token) }
                       .min { name($0).count < name($1).count }
        guard let family,
              let files = try? fm.contentsOfDirectory(at: family, includingPropertiesForKeys: nil)
        else { return nil }

        // These families ship a light and a dark cut, and a landscape and a portrait one.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let size = (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? .zero
        let landscape = size.width >= size.height
        func pick(_ terms: [String]) -> URL? {
            files.first { u in
                let n = u.lastPathComponent.lowercased()
                return terms.allSatisfy { n.contains($0) }
            }
        }
        return pick([dark ? "dark" : "light", landscape ? "landscape" : "portrait"])
            ?? pick([dark ? "dark" : "light"])
            ?? files.first
    }
}
