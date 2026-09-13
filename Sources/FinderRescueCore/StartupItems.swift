import Foundation

public enum LaunchScope: String, Sendable {
    case user = "Your agent"
    case backup = "Turned off"
    case global = "All users"
    case daemon = "System daemon"
}

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let label: String
    public let path: String
    public let scope: LaunchScope
    public let command: String
    public let missingPath: String?
    public let schedule: String
    public let pid: Int?
    public let lastExit: Int?
    public let overrideDisabled: Bool
    public let loaded: Bool

    public var enabled: Bool { scope != .backup && !overrideDisabled }
    public var editable: Bool { scope != .daemon }

    /// Only reported for items that are on — a turned-off item is already dealt with.
    public var problem: String? {
        guard enabled else { return nil }
        if let missingPath { return "Missing file: " + (missingPath as NSString).abbreviatingWithTildeInPath }
        // Exits from being stopped (SIGKILL/SIGTERM) aren't failures.
        if let e = lastExit, e != 0, ![-9, -15, 137, 143].contains(e) { return "Last run failed (exit \(e))" }
        return nil
    }

    public var status: String {
        if !enabled { return "Off" }
        if scope == .daemon { return "System" }
        if let pid { return "Running · \(pid)" }
        return loaded ? "Idle" : "Not loaded"
    }
}

/// Reads and toggles launchd jobs. Turning off one of the user's own agents unloads it and moves
/// its plist into a backup folder, so turning it back on restores it exactly.
public enum StartupItems {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    public static var userDir: String { home + "/Library/LaunchAgents" }
    public static var backupDir: String { home + "/Library/LaunchAgents-disabled-FinderRescue" }
    static var domain: String { "gui/\(getuid())" }

    public struct ToggleError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    struct Job: Equatable {
        let pid: Int?
        let status: Int?
    }

    public static func scan() -> [LaunchItem] {
        let jobs = parseLaunchctlList(Shell.run("/bin/launchctl", ["list"]).out)
        let disabled = parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", domain]).out)
        var dirs: [(String, LaunchScope)] = [(userDir, .user)]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home + "/Library") {
            for entry in entries.sorted() where entry.hasPrefix("LaunchAgents-disabled") {
                dirs.append((home + "/Library/" + entry, .backup))
            }
        }
        dirs += [("/Library/LaunchAgents", .global), ("/Library/LaunchDaemons", .daemon)]

        var items: [LaunchItem] = []
        for (dir, scope) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }
                let label = plist["Label"] as? String ?? String(file.dropLast(6))
                let args = plist["ProgramArguments"] as? [String] ?? []
                let program = plist["Program"] as? String ?? args.first ?? ""
                let job = scope == .backup ? nil : jobs[label]
                items.append(LaunchItem(
                    label: label, path: path, scope: scope,
                    command: commandLine(program: program, args: args),
                    missingPath: missingFile(program: program, args: args),
                    schedule: schedule(plist),
                    pid: job?.pid, lastExit: job?.status,
                    overrideDisabled: disabled.contains(label),
                    loaded: job != nil))
            }
        }
        return items
    }

    public static func setEnabled(_ item: LaunchItem, _ on: Bool) throws {
        let fm = FileManager.default
        let target = "\(domain)/\(item.label)"
        switch (item.scope, on) {
        case (.daemon, _):
            throw ToggleError(message: "System daemons need an administrator. Use System Settings → General → Login Items & Extensions.")
        case (.user, false):
            Shell.run("/bin/launchctl", ["bootout", target])
            Shell.run("/bin/launchctl", ["disable", target])
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            let dest = backupDir + "/" + (item.path as NSString).lastPathComponent
            if fm.fileExists(atPath: dest) {
                try fm.moveItem(atPath: dest, toPath: dest + ".old-\(Int(Date().timeIntervalSince1970))")
            }
            try fm.moveItem(atPath: item.path, toPath: dest)
        case (.backup, true):
            let dest = userDir + "/" + (item.path as NSString).lastPathComponent
            guard !fm.fileExists(atPath: dest) else {
                throw ToggleError(message: "\((dest as NSString).lastPathComponent) already exists in LaunchAgents.")
            }
            try fm.moveItem(atPath: item.path, toPath: dest)
            Shell.run("/bin/launchctl", ["enable", target])
            Shell.run("/bin/launchctl", ["bootstrap", domain, dest])
        case (.user, true), (.global, true):
            Shell.run("/bin/launchctl", ["enable", target])
            Shell.run("/bin/launchctl", ["bootstrap", domain, item.path])
        case (.global, false):
            // /Library agents can't be moved without admin rights, but can be switched off for this user.
            Shell.run("/bin/launchctl", ["bootout", target])
            Shell.run("/bin/launchctl", ["disable", target])
        case (.backup, false):
            break
        }
    }

    // MARK: - Parsing (internal for tests)

    static func parseLaunchctlList(_ text: String) -> [String: Job] {
        var map: [String: Job] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            map[String(cols[2])] = Job(pid: Int(cols[0]), status: Int(cols[1]))
        }
        return map
    }

    static func parseDisabled(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), t.hasSuffix("disabled") || t.hasSuffix("true") else { continue }
            let body = t.dropFirst()
            if let end = body.firstIndex(of: "\"") { labels.insert(String(body[..<end])) }
        }
        return labels
    }

    private static let interpreters: Set<String> = ["bash", "sh", "zsh", "perl", "ruby", "node", "osascript"]

    /// A missing program — or a missing script handed to an interpreter — means the job can never work.
    static func missingFile(program: String, args: [String], exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        guard !program.isEmpty else { return nil }
        if program.hasPrefix("/") && !exists(program) { return program }
        let name = (program as NSString).lastPathComponent
        if interpreters.contains(name) || name.hasPrefix("python") {
            // An inline command (`bash -c "a.sh ; b.sh"`) isn't a single script path we can check.
            if args.contains("-c") || args.contains("-e") { return nil }
            if let script = args.dropFirst().first(where: { $0.hasPrefix("/") }), !exists(script) {
                return script
            }
        }
        return nil
    }

    static func commandLine(program: String, args: [String]) -> String {
        let parts = [program] + args.dropFirst()
        return parts.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " ")
    }

    static func schedule(_ p: [String: Any]) -> String {
        if let keepAlive = p["KeepAlive"] {
            if (keepAlive as? Bool) == true { return "Always running" }
            if keepAlive is [String: Any] { return "Kept alive" }
        }
        if let seconds = p["StartInterval"] as? Int { return "Every " + duration(seconds) }
        if let calendar = p["StartCalendarInterval"] { return describeCalendar(calendar) }
        if p["WatchPaths"] != nil || p["QueueDirectories"] != nil { return "When files change" }
        if (p["RunAtLoad"] as? Bool) == true { return "At login" }
        return "On demand"
    }

    private static func duration(_ s: Int) -> String {
        if s % 3600 == 0 { return "\(s / 3600) h" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s) s"
    }

    private static func describeCalendar(_ value: Any) -> String {
        let entries = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
        guard let e = entries.first else { return "Scheduled" }
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var text: String
        if let hour = e["Hour"] as? Int {
            text = String(format: "%02d:%02d", hour, e["Minute"] as? Int ?? 0)
        } else if let minute = e["Minute"] as? Int {
            text = String(format: "Hourly at :%02d", minute)
        } else {
            text = "Scheduled"
        }
        if let weekday = e["Weekday"] as? Int, days.indices.contains(weekday) {
            text = days[weekday] + " " + text
        } else if e["Day"] != nil {
            text = "Monthly " + text
        } else if e["Hour"] != nil {
            text = "Daily " + text
        }
        if entries.count > 1 { text += " (+\(entries.count - 1))" }
        return text
    }
}
