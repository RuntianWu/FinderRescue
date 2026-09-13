import Foundation

/// One-shot fixes. All of these block, so call them off the main thread.
public enum FinderActions {
    /// Quits Finder and waits for launchd to bring it back; falls back to `open -a Finder`.
    public static func relaunchFinder() {
        guard let old = ProcessStats.finderPID() else {
            Shell.run("/usr/bin/open", ["-a", "Finder"])
            return
        }
        kill(old, SIGTERM)
        if !waitUntil(seconds: 5, { kill(old, 0) != 0 }) {
            kill(old, SIGKILL)
            waitUntil(seconds: 3, { kill(old, 0) != 0 })
        }
        if !waitUntil(seconds: 6, { ProcessStats.finderPID().map { $0 != old } ?? false }) {
            Shell.run("/usr/bin/open", ["-a", "Finder"])
        }
    }

    @discardableResult
    static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    public static func closeSearchWindows() -> String {
        let r = Shell.osascript([
            "with timeout of 10 seconds",
            "tell application \"Finder\"",
            "set closedCount to 0",
            "set ws to every Finder window",
            "repeat with i from (count of ws) to 1 by -1",
            "set w to item i of ws",
            "try",
            "set n to name of w",
            "if n starts with \"Searching\" or n starts with \"搜索\" then",
            "close w",
            "set closedCount to closedCount + 1",
            "end if",
            "end try",
            "end repeat",
            "return closedCount",
            "end tell",
            "end timeout",
        ], timeout: 15)
        if r.ok {
            let n = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return n == 0 ? "No search windows were open" : "Closed \(n) search window\(n == 1 ? "" : "s")"
        }
        return describeAppleScriptFailure(r)
    }

    public static func describeAppleScriptFailure(_ r: ShellResult) -> String {
        if r.err.contains("-1743") || r.err.localizedCaseInsensitiveContains("not authori") {
            return "Allow Finder Rescue to control Finder in System Settings → Privacy & Security → Automation"
        }
        if r.timedOut || r.err.contains("-1712") {
            return "Finder didn't answer — use Relaunch Finder instead"
        }
        return "Finder returned an error: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resetQuickLook() -> String {
        Shell.run("/usr/bin/qlmanage", ["-r"])
        Shell.run("/usr/bin/qlmanage", ["-r", "cache"])
        Shell.run("/usr/bin/pkill", ["-x", "QuickLookUIService"])
        Shell.run("/usr/bin/pkill", ["-x", "quicklookd"])
        return "Quick Look was reset"
    }
}

/// Reads and writes other apps' preferences through `defaults`, which goes via cfprefsd
/// (editing plist files directly is undone by cfprefsd's cache).
public enum Prefs {
    public static func bool(_ domain: String, _ key: String) -> Bool {
        let v = (string(domain, key) ?? "").lowercased()
        return ["1", "yes", "true"].contains(v)
    }

    public static func string(_ domain: String, _ key: String) -> String? {
        let r = Shell.run("/usr/bin/defaults", ["read", domain, key])
        guard r.ok else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func setBool(_ domain: String, _ key: String, _ on: Bool) {
        Shell.run("/usr/bin/defaults", ["write", domain, key, "-bool", on ? "true" : "false"])
    }

    public static func setString(_ domain: String, _ key: String, _ value: String) {
        Shell.run("/usr/bin/defaults", ["write", domain, key, "-string", value])
    }
}
