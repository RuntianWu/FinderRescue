import Foundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import FinderRescueCore

// MARK: - App preferences

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults = UserDefaults.standard

    @Published var autoCheckForUpdates: Bool {
        didSet {
            defaults.set(autoCheckForUpdates, forKey: "autoCheckForUpdates")
            UpdateChecker.shared.startAutomaticChecking()
        }
    }

    @Published var hotKeyEnabled: Bool {
        didSet {
            defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
            if hotKeyEnabled { HotKey.shared.register() } else { HotKey.shared.unregister() }
        }
    }

    private init() {
        defaults.register(defaults: ["autoCheckForUpdates": true, "hotKeyEnabled": true])
        autoCheckForUpdates = defaults.bool(forKey: "autoCheckForUpdates")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
    }
}

enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Global keyboard shortcut

/// ⌃⌥⌘F relaunches Finder from anywhere — useful exactly when Finder is too stuck to click.
/// Uses the Carbon hot-key API, which (unlike a keystroke tap) needs no Accessibility permission.
@MainActor
final class HotKey {
    static let shared = HotKey()
    static let displayString = "⌃⌥⌘F"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    private init() {}

    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in
                FinderMonitor.shared.rescue(reason: "Relaunched with \(HotKey.displayString)", automatic: false)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4652_5343), id: 1) // 'FRSC'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr
        if !isRegistered { NSLog("Finder Rescue: couldn't register \(Self.displayString) (status \(status))") }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        isRegistered = false
    }
}

// MARK: - Update checks

/// Checks GitHub Releases for a newer version. It never downloads or installs anything — it tells
/// you a new version exists and links to the release page (there's no Developer ID/Sparkle setup).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "Micropeptide/FinderRescue"
    static let repoURL = URL(string: "https://github.com/Micropeptide/FinderRescue")!
    static let releasesURL = URL(string: "https://github.com/Micropeptide/FinderRescue/releases")!

    struct Update: Equatable {
        let version: String
        let url: URL
    }

    @Published private(set) var availableUpdate: Update?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private init() {
        lastChecked = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Checks at launch if the last check was over a day ago, then re-evaluates every 6 hours.
    func startAutomaticChecking() {
        timer?.invalidate()
        timer = nil
        guard AppPreferences.shared.autoCheckForUpdates else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard AppPreferences.shared.autoCheckForUpdates else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 20 * 3600 { return }
        Task { await checkNow(userInitiated: false) }
    }

    func checkNow(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let monitor = FinderMonitor.shared
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if userInitiated {
                    monitor.notify(title: "Couldn't check for updates", body: "GitHub didn't return release information. Try again later.")
                }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: "lastUpdateCheck")
            let latest = Version.normalize(release.tag_name)
            if Version.isNewer(latest, than: currentVersion), let url = URL(string: release.html_url) {
                availableUpdate = Update(version: latest, url: url)
                // Notify once per version unless asked.
                if userInitiated || defaults.string(forKey: "notifiedVersion") != latest {
                    defaults.set(latest, forKey: "notifiedVersion")
                    monitor.notify(title: "Finder Rescue \(latest) is available",
                                   body: "You have \(currentVersion). Click to open the download page.",
                                   category: "UPDATE", userInfo: ["url": url.absoluteString])
                }
            } else {
                availableUpdate = nil
                if userInitiated {
                    monitor.notify(title: "Finder Rescue is up to date", body: "You have the latest version (\(currentVersion)).")
                }
            }
        } catch {
            if userInitiated {
                monitor.notify(title: "Couldn't check for updates", body: "No response from GitHub. Check your connection and try again.")
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }
}

// MARK: - Windows and URL commands

extension Notification.Name {
    static let openAppWindow = Notification.Name("FinderRescue.openWindow")
}

enum AppWindow {
    static let main = "main"
    static let about = "about"

    /// Asks the always-alive menu-bar label to open a window (it holds the SwiftUI `openWindow` action).
    static func open(_ id: String) {
        NotificationCenter.default.post(name: .openAppWindow, object: id)
    }
}

/// `finderrescue://` links, for Shortcuts, scripts, Raycast/Alfred, etc.
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        let monitor = FinderMonitor.shared
        switch (url.host ?? "").lowercased() {
        case "relaunch":
            monitor.rescue(reason: "Relaunched from a finderrescue:// link", automatic: false)
        case "close-search":
            monitor.perform("Closing search windows…", FinderActions.closeSearchWindows)
        case "reset-quicklook":
            monitor.perform("Resetting Quick Look…", FinderActions.resetQuickLook)
        case "snooze":
            monitor.snooze()
        case "resume":
            monitor.resumeAutoRescue()
        case "check-updates":
            Task { await UpdateChecker.shared.checkNow(userInitiated: true) }
        case "about":
            AppWindow.open(AppWindow.about)
        default:
            AppWindow.open(AppWindow.main)
        }
    }
}
