import Foundation

public struct RescueEvent: Codable, Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let reason: String
    public let automatic: Bool
    public let cpu: Double
    public let footprintMB: Double
    public let samplePath: String?

    public init(date: Date, reason: String, automatic: Bool, cpu: Double, footprintMB: Double, samplePath: String?) {
        self.date = date
        self.reason = reason
        self.automatic = automatic
        self.cpu = cpu
        self.footprintMB = footprintMB
        self.samplePath = samplePath
    }
}

/// Rescue history (JSON lines) and diagnostic samples, kept in ~/Library/Logs/FinderRescue.
public enum RescueLog {
    public static let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FinderRescue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var file: URL { dir.appendingPathComponent("rescues.jsonl") }
    private static let lock = NSLock()

    public static func append(_ event: RescueEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// Newest first.
    public static func load() -> [RescueEvent] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(text.split(separator: "\n")
            .compactMap { try? decoder.decode(RescueEvent.self, from: Data($0.utf8)) }
            .reversed())
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
    }

    /// Records 3 s of Finder call stacks so the cause of a hang can be looked at later.
    public static func captureSample(pid: pid_t) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = dir.appendingPathComponent("Finder-sample-\(formatter.string(from: Date())).txt")
        Shell.run("/usr/bin/sample", [String(pid), "3", "-mayDie", "-file", url.path], timeout: 45)
        prune()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private static func prune(keep: Int = 20) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let samples = files.filter { $0.lastPathComponent.hasPrefix("Finder-sample-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in samples.dropFirst(keep) { try? fm.removeItem(at: url) }
    }
}
