import Foundation

public struct FinderExtension: Identifiable, Hashable, Sendable {
    public let id: String
    public let appName: String
    public let kind: String
    public let path: String
    public let enabled: Bool
    public var isApple: Bool { id.hasPrefix("com.apple.") }
}

/// Cloud-storage (File Provider) and Finder Sync extensions, toggled with pluginkit.
public enum Extensions {
    private static let kinds = [
        ("com.apple.fileprovider-nonui", "Cloud storage"),
        ("com.apple.FinderSync", "Finder add-on"),
    ]

    public static func scan() -> [FinderExtension] {
        var result: [FinderExtension] = []
        var seen = Set<String>()
        for (proto, kind) in kinds {
            for ext in parse(Shell.run("/usr/bin/pluginkit", ["-mAvv", "-p", proto]).out, kind: kind)
            where !seen.contains(ext.id) {
                seen.insert(ext.id)
                result.append(ext)
            }
        }
        return result.sorted { ($0.isApple ? 1 : 0, $0.appName) < ($1.isApple ? 1 : 0, $1.appName) }
    }

    public static func setEnabled(_ ext: FinderExtension, _ on: Bool) {
        Shell.run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", ext.id])
    }

    /// Parses `pluginkit -mAvv` output. Header lines look like "-    com.example.ext(1.0)", where
    /// the first column is the user's election ("-" = turned off); detail lines start with a tab;
    /// the listing ends with a summary like "(7 plug-ins)".
    static func parse(_ output: String, kind: String) -> [FinderExtension] {
        var result: [FinderExtension] = []
        var current: (id: String, enabled: Bool)?
        var path = ""
        func flush() {
            guard let c = current, !result.contains(where: { $0.id == c.id }) else { return }
            result.append(FinderExtension(id: c.id, appName: appName(path, fallback: c.id),
                                          kind: kind, path: path, enabled: c.enabled))
        }
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("\t") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Path = ") { path = String(t.dropFirst(7)) }
                continue
            }
            flush()
            current = nil
            path = ""
            let flag = line.first.map(String.init) ?? " "
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty, !rest.hasPrefix("(") else { continue }
            current = (rest.split(separator: "(").first.map(String.init) ?? rest, flag != "-")
        }
        flush()
        return result
    }

    static func appName(_ path: String, fallback: String) -> String {
        if fallback.hasPrefix("com.apple.CloudDocs") {
            return fallback.hasSuffix("Managed") ? "iCloud Drive (managed)" : "iCloud Drive"
        }
        let comps = path.split(separator: "/")
        if let app = comps.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        if let appex = comps.first(where: { $0.hasSuffix(".appex") }) { return String(appex.dropLast(6)) }
        return fallback
    }
}
