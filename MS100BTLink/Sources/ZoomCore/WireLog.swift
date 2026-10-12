import Foundation

/// Append-only JSONL log: one line per sent/received chunk or note.
/// `{"t":"2026-10-11T18:49:00.123Z","dir":"tx","hex":"F0 7E 00 06 01 F7","note":"identity request"}`
public final class WireLog {
    public enum Direction: String { case tx, rx, note }

    public let url: URL
    private let handle: FileHandle
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(directory: URL, prefix: String = "") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let name = (prefix.isEmpty ? "" : prefix + "-") + stamp.string(from: Date()) + ".jsonl"
        url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    public func record(_ dir: Direction, _ bytes: [UInt8] = [], note: String? = nil) {
        var obj: [String: Any] = ["t": formatter.string(from: Date()), "dir": dir.rawValue]
        if !bytes.isEmpty || dir != .note { obj["hex"] = bytes.hex }
        if let note { obj["note"] = note }
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        handle.write(line)
    }

    public func note(_ text: String) { record(.note, note: text) }

    /// Default directory for the CLI: `./logs`.
    public static var cliDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("logs")
    }

    /// Default directory for the app: `~/Library/Logs/MS100BTLink`.
    public static var appDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MS100BTLink")
    }
}
