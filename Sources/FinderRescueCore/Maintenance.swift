import Foundation
import Darwin

public struct NetworkMount: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let source: String
    public let type: String
    public var responsive: Bool?
}

/// Which folder a new Finder window opens (`NewWindowTarget` in com.apple.finder).
public enum NewWindowTarget: String, CaseIterable, Identifiable, Sendable {
    case recents = "PfAF", home = "PfHm", desktop = "PfDe", documents = "PfDo", computer = "PfCm", other = "PfLo"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recents: return "Recents"
        case .home: return "Home"
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .computer: return "Computer"
        case .other: return "A specific folder"
        }
    }
}

/// The less-common repairs. Everything here works without administrator rights, and anything that
/// changes settings either backs up first or is trivially reversible.
public enum Maintenance {
    public static let desktopServices = "com.apple.desktopservices"
    public static let finderDomain = "com.apple.finder"

    // MARK: Network mounts

    /// Network file systems currently mounted. Uses MNT_NOWAIT so a dead server can't block us.
    public static func networkMounts() -> [NetworkMount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // `statfs` is both a struct and a function in Swift, so allocate the buffer explicitly.
        let capacity = Int(count) + 8
        let pointer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        let n = getfsstat(pointer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        let filled = UnsafeBufferPointer(start: pointer, count: Int(max(0, min(n, Int32(capacity)))))
        let networkTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"]
        return filled.compactMap { fs in
            let type = cString(fs.f_fstypename)
            guard networkTypes.contains(type) else { return nil }
            return NetworkMount(path: cString(fs.f_mntonname), source: cString(fs.f_mntfromname), type: type)
        }
    }

    /// Probes a mount in a child process with a short timeout, so a hang there can't freeze us.
    public static func probe(_ mount: NetworkMount) -> Bool {
        Shell.run("/usr/bin/stat", ["-f", "%N", mount.path], timeout: 4).ok
    }

    public static func forceUnmount(_ mount: NetworkMount) -> String {
        let r = Shell.run("/usr/sbin/diskutil", ["unmount", "force", mount.path], timeout: 30)
        if r.ok { return "Disconnected \(mount.path)" }
        let fallback = Shell.run("/sbin/umount", ["-f", mount.path], timeout: 30)
        if fallback.ok { return "Disconnected \(mount.path)" }
        return "Couldn't disconnect \(mount.path). If it stays stuck, turning Wi-Fi off and on usually releases it."
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // MARK: Background services

    /// Quits a per-user background service; launchd starts it again right away.
    public static func restartService(_ name: String, title: String) -> String {
        let r = Shell.run("/usr/bin/killall", [name], timeout: 10)
        return r.ok ? "\(title) was restarted" : "Couldn't restart \(title): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // MARK: Open/Save dialogs

    public static func resetOpenSavePanel() -> String {
        Shell.run("/usr/bin/defaults", ["delete", "com.apple.appkit.xpc.openAndSavePanelService"])
        Shell.run("/usr/bin/pkill", ["-f", "com.apple.appkit.xpc.openAndSavePanelService"])
        return "Open and Save dialogs were reset"
    }

    // MARK: Finder preferences

    public static var backupDir: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Finder Rescue/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func backupFinderPrefs() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = backupDir.appendingPathComponent("com.apple.finder-\(formatter.string(from: Date())).plist")
        let r = Shell.run("/usr/bin/defaults", ["export", finderDomain, url.path])
        return r.ok && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func latestFinderBackup() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("com.apple.finder-") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Backs up, deletes all Finder settings, and relaunches Finder. Refuses if the backup fails.
    public static func resetFinderPrefs() -> String {
        guard let backup = backupFinderPrefs() else {
            return "Couldn't back up Finder's settings, so nothing was changed."
        }
        Shell.run("/usr/bin/defaults", ["delete", finderDomain])
        FinderActions.relaunchFinder()
        return "Finder settings were reset. A backup was saved as \(backup.lastPathComponent)."
    }

    public static func restoreFinderPrefs(from url: URL) -> String {
        let r = Shell.run("/usr/bin/defaults", ["import", finderDomain, url.path])
        guard r.ok else { return "Couldn't restore \(url.lastPathComponent)." }
        FinderActions.relaunchFinder()
        return "Finder settings were restored from \(url.lastPathComponent)."
    }

    // MARK: Spotlight

    public static func spotlightStatus() -> String {
        let out = Shell.run("/usr/bin/mdutil", ["-s", "/System/Volumes/Data"], timeout: 10).out
        let status = out.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return status ?? "Unknown"
    }
}
