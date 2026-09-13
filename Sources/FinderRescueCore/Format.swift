import Foundation

public enum Fmt {
    public static func mb(_ value: Double) -> String {
        value >= 1024 ? String(format: "%.1f GB", value / 1024) : "\(Int(value)) MB"
    }

    public static func minutes(_ value: Double) -> String {
        Int(value) == 1 ? "1 minute" : "\(Int(value)) minutes"
    }

    public static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value)) s"
    }

    public static func uptime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) m" }
        return "\(s / 86400) d \(s % 86400 / 3600) h"
    }

    public static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
