import SwiftUI
import CoreServices
import UserNotifications
import FinderRescueCore

@main
struct FinderRescueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = FinderMonitor.shared
    @StateObject private var updates = UpdateChecker.shared
    @StateObject private var prefs = AppPreferences.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(monitor)
                .environmentObject(updates)
        } label: {
            MenuBarLabel(symbol: monitor.health.symbol)
        }
        .menuBarExtraStyle(.window)

        Window("Finder Rescue", id: AppWindow.main) {
            MainView()
                .environmentObject(monitor)
                .environmentObject(updates)
                .environmentObject(prefs)
        }
        .defaultSize(width: 960, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Window("About Finder Rescue", id: AppWindow.about) {
            AboutView().environmentObject(updates)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The status-bar icon. It stays alive for the app's lifetime, so it also opens windows on request
/// (from notifications, `finderrescue://` links, or reopening the app from Spotlight/Launchpad).
struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Finder Rescue")
            .onReceive(NotificationCenter.default.publisher(for: .openAppWindow)) { note in
                openWindow(id: note.object as? String ?? AppWindow.main)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let relaunch = UNNotificationAction(identifier: "RELAUNCH", title: "Relaunch Finder", options: [])
        let relaunchNow = UNNotificationAction(identifier: "RELAUNCH", title: "Relaunch Now", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Not Now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "STUCK", actions: [relaunch], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "PENDING", actions: [relaunchNow, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "UPDATE", actions: [], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        MainActor.assumeIsolated {
            FinderMonitor.shared.start()
            if AppPreferences.shared.hotKeyEnabled { HotKey.shared.register() }
            UpdateChecker.shared.startAutomaticChecking()
        }

        // Monitoring only works while the app runs, so start at login by default (switchable in settings).
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didFirstRun") {
            defaults.set(true, forKey: "didFirstRun")
            try? LaunchAtLogin.set(true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindow.open(AppWindow.main)
        return false
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated { URLCommands.handle(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let link = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            switch action {
            case "RELAUNCH":
                FinderMonitor.shared.rescue(reason: "Relaunched from a notification", automatic: false)
            case "SNOOZE":
                FinderMonitor.shared.snooze()
            case UNNotificationDefaultActionIdentifier:
                if category == "UPDATE", let link, let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                } else {
                    AppWindow.open(AppWindow.main)
                }
            default:
                break
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
