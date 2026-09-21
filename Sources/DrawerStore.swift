import AppKit
import QuickLookThumbnailing

// MARK: - What the drawer holds

enum DrawerItemKind: String, Codable {
    case text, image, file
}

struct DrawerItem: Codable, Equatable {
    let id: UUID
    let kind: DrawerItemKind
    /// What the tile is captioned with: a filename, or the first line of some text.
    let label: String
    /// For `.text` and `.image`, the blob's filename inside the store's folder. For `.file`, the
    /// path of the original on disk - the file itself is left where the user put it.
    let payload: String
    let added: Date

    /// Where the thing sits, as a fraction of the drawer's width and height, measured to the
    /// centre of the tile.
    ///
    /// Fractions rather than points, because the drawer is sized from the display and the
    /// display changes: plug in a monitor and a drawer laid out in points would have half its
    /// contents off the edge. Fractions keep an arrangement recognisably the same arrangement
    /// at any size.
    var x: Double
    var y: Double

    /// The shape of the thing: its width over its height.
    ///
    /// Remembered rather than measured each time, because it is only knowable once something has
    /// drawn the preview - a PDF's proportions are its first page's, which QuickLook has to
    /// render before anyone knows what they are. Nil until then, and a tile with no aspect yet
    /// is laid out square and corrects itself the moment the picture arrives.
    var aspect: Double?

    enum CodingKeys: String, CodingKey { case id, kind, label, payload, added, x, y, aspect }

    init(id: UUID, kind: DrawerItemKind, label: String, payload: String,
         added: Date, x: Double, y: Double, aspect: Double? = nil) {
        self.id = id; self.kind = kind; self.label = label
        self.payload = payload; self.added = added
        self.x = x; self.y = y; self.aspect = aspect
    }

    /// Positions are decoded leniently so a drawer written before they existed still opens; its
    /// contents pile up in the top left and can be dragged apart.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(DrawerItemKind.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        payload = try c.decode(String.self, forKey: .payload)
        added = try c.decode(Date.self, forKey: .added)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.1
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.1
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
    }
}

/// The drawer's contents, kept on disk so they survive a restart.
///
/// Text and images are copied into the store's own folder, because a clipboard has no file
/// behind it and there would otherwise be nothing to come back to. Files are *not* copied: a
/// dragged-in file is a reference to something the user already keeps somewhere, and duplicating
/// it would mean the drawer silently hoarding gigabytes and handing back stale copies of files
/// that have since been edited.
final class DrawerStore {
    private(set) var items: [DrawerItem] = []

    private let folder: URL
    private var index: URL { folder.appendingPathComponent("index.json") }
    private var thumbnails: [UUID: NSImage] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Shady/Drawer", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: index),
              let decoded = try? JSONDecoder().decode([DrawerItem].self, from: data)
        else { return }
        // Anything whose blob has gone - the folder emptied by hand, a referenced file moved or
        // deleted - is dropped rather than left as a tile that does nothing when clicked.
        items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        if items.count != decoded.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: index, options: .atomic)
    }

    func url(for item: DrawerItem) -> URL {
        item.kind == .file ? URL(fileURLWithPath: item.payload)
                           : folder.appendingPathComponent(item.payload)
    }

    /// Whether there is room for one more.
    var hasRoom: Bool { items.count < Config.drawerCapacity }

    // MARK: Taking things in

    /// The thing on the clipboard, if the drawer already has it.
    ///
    /// Compared by content, not by name: two screenshots taken a second apart have different
    /// names and the same pixels, and the same paragraph copied twice from two places is the
    /// same paragraph. A file is the exception - there it is the path that identifies it, since
    /// the point of keeping a file is the file at that location, not its bytes at one moment.
    func existing(matching board: NSPasteboard) -> DrawerItem? {
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return items.first { $0.kind == .file && $0.payload == url.path }
        }

        if let image = NSImage(pasteboard: board), let png = image.pngData() {
            return items.first { item in
                item.kind == .image
                    && (try? Data(contentsOf: self.url(for: item))) == png
            }
        }

        if let text = board.string(forType: .string) {
            return items.first { $0.kind == .text && self.text(of: $0) == text }
        }

        return nil
    }

    /// Reads whatever is on the pasteboard into a new item, newest first.
    ///
    /// The order the pasteboard is asked in is the order of specificity, not of convenience.
    /// Copying a file in Finder puts a file URL *and* a string of its path on the board; copying
    /// an image from a browser puts image data and often a URL string too. Asking for the richest
    /// representation first is what makes a pasted file arrive as a file rather than as a tile
    /// showing "/Users/you/Downloads/thing.pdf".
    @discardableResult
    func add(from board: NSPasteboard, at position: CGPoint) -> DrawerItem? {
        let x = Double(position.x), y = Double(position.y)
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return insert(DrawerItem(id: UUID(), kind: .file,
                                     label: url.lastPathComponent,
                                     payload: url.path, added: Date(), x: x, y: y))
        }

        if let image = NSImage(pasteboard: board), let png = image.pngData() {
            let name = "\(UUID().uuidString).png"
            guard (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return nil }
            // A pasted image is the one case where the shape is known straight away, so the
            // tile is never briefly the wrong one.
            let aspect = image.size.height > 0 ? Double(image.size.width / image.size.height) : nil
            return insert(DrawerItem(id: UUID(), kind: .image,
                                     label: "Image", payload: name, added: Date(),
                                     x: x, y: y, aspect: aspect))
        }

        if let text = board.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = "\(UUID().uuidString).txt"
            guard (try? Data(text.utf8).write(to: folder.appendingPathComponent(name))) != nil
            else { return nil }
            return insert(DrawerItem(id: UUID(), kind: .text,
                                     label: DrawerStore.firstLine(of: text),
                                     payload: name, added: Date(), x: x, y: y))
        }

        return nil
    }

    private func insert(_ item: DrawerItem) -> DrawerItem {
        items.insert(item, at: 0)
        save()
        return item
    }

    /// The shape a preview turned out to be, learned once and kept.
    func noteAspect(_ aspect: Double, for item: DrawerItem) {
        guard aspect.isFinite, aspect > 0,
              let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].aspect != aspect
        else { return }
        items[index].aspect = aspect
        save()
    }

    /// Where something has been dragged to.
    func move(_ item: DrawerItem, to position: CGPoint) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].x = Double(position.x)
        items[index].y = Double(position.y)
        save()
    }

    private static func firstLine(of text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    // MARK: Giving them back

    /// Puts an item back on the clipboard in the form it came off it.
    func copyToPasteboard(_ item: DrawerItem) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .file:
            board.writeObjects([url(for: item) as NSURL])
        case .image:
            if let image = NSImage(contentsOf: url(for: item)) { board.writeObjects([image]) }
        case .text:
            board.setString(text(of: item) ?? item.label, forType: .string)
        }
    }

    func text(of item: DrawerItem) -> String? {
        guard item.kind == .text else { return nil }
        return try? String(contentsOf: url(for: item), encoding: .utf8)
    }

    func remove(_ item: DrawerItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        // Only ever the store's own copy. A `.file` item's payload is the user's file.
        if item.kind != .file { try? FileManager.default.removeItem(at: url(for: item)) }
        save()
    }

    func remove(_ list: [DrawerItem]) { list.forEach(remove) }

    // MARK: Tiles

    /// The picture a tile shows.
    ///
    /// Asked of QuickLook, which is the same machinery Finder and Spotlight use: it renders the
    /// first page of a PDF, a frame of a video, the artwork of a song, the actual content of a
    /// Pages document. A generic icon is only the fallback, for the file types nothing knows how
    /// to draw.
    ///
    /// Nothing is generated twice. The result is cached in memory for as long as the app runs -
    /// this is asked for on every rebuild of the grid, and re-rendering a video's poster frame
    /// each time the curtain opens is exactly the kind of work that makes it stutter.
    ///
    /// Asynchronous because it has to be: a thumbnail can mean decoding a RAW photograph, and
    /// doing that on the main thread is a visible hitch in a curtain that is still moving. The
    /// tile draws empty and fills in when the picture arrives, usually within a frame or two.
    func thumbnail(for item: DrawerItem, size: CGSize,
                   completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnails[item.id] { completion(cached); return }
        guard item.kind != .text else { completion(nil); return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let file = url(for: item)
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: size, scale: scale,
            representationTypes: .all)

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep.map { NSImage(cgImage: $0.cgImage, size: .zero) }
                ?? self?.fallbackIcon(for: item)
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnails[item.id] = image
                completion(image)
            }
        }
    }

    /// What a file looks like when nothing can draw its contents: its type's icon.
    private func fallbackIcon(for item: DrawerItem) -> NSImage? {
        guard item.kind == .file else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: item.payload)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
