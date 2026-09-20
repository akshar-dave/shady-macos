import Foundation

// MARK: - Debug logging

/// Diagnostics are opt-in via marker files rather than environment variables, so they work when
/// the app is launched by launchd (where the Accessibility prompt is attributed correctly) and
/// not just from a shell.
///
///   touch ~/.shady-debug   # gesture decisions
///   touch ~/.shady-trace   # every event the system delivers
///   tail -f ~/Library/Logs/Shady.log
enum DebugLog {
    private static let path = ("~/Library/Logs/Shady.log" as NSString).expandingTildeInPath
    private static func marker(_ n: String) -> Bool {
        FileManager.default.fileExists(atPath: ("~/" + n as NSString).expandingTildeInPath)
    }
    static let enabled: Bool = marker(".shady-debug") || marker(".shady-trace")

    /// One handle, opened once. Opening a file per event is far too slow for an input path.
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        return FileHandle(forWritingAtPath: path)
    }()
    private static let queue = DispatchQueue(label: "shade.log", qos: .utility)

    /// Writes off the caller's thread: this is called from an input path that must never block.
    static func write(_ m: String) {
        guard enabled, let h = handle else { return }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(m)\n"
        queue.async {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
        }
    }
}
