import SwiftUI
import AppKit
import FinderRescueCore

struct FixesTab: View {
    @EnvironmentObject var m: FinderMonitor
    @State private var fix: Fix?
    @State private var showHidden = false
    @State private var previewPane = false
    @State private var newWindow: NewWindowTarget = .recents
    @State private var noNetworkStores = false
    @State private var noUSBStores = false
    @State private var spotlight = "Checking…"
    @State private var backup: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden files", isOn: Binding(get: { showHidden }, set: { v in
                    showHidden = v
                    applyFinder("Updating Finder…") { Prefs.setBool(Maintenance.finderDomain, "AppleShowAllFiles", v) }
                }))
                Toggle("Show the preview pane", isOn: Binding(get: { previewPane }, set: { v in
                    previewPane = v
                    applyFinder("Updating Finder…") { Prefs.setBool(Maintenance.finderDomain, "ShowPreviewPane", v) }
                }))
                Picker("New Finder windows open", selection: Binding(get: { newWindow }, set: { v in
                    newWindow = v
                    guard v != .other else { return }
                    applyFinder("Updating Finder…") { Prefs.setString(Maintenance.finderDomain, "NewWindowTarget", v.rawValue) }
                })) {
                    ForEach(NewWindowTarget.allCases.filter { $0 != .other || newWindow == .other }) {
                        Text($0.title).tag($0)
                    }
                }
            } header: {
                Text("Finder settings")
            } footer: {
                Text("Hidden files and the preview pane both give Finder more work in every folder. Recents is a live Spotlight search, so windows that open on it are slower than Home. Changing any of these relaunches Finder. Shortcuts: ⌘⇧. toggles hidden files, ⌘⇧P the preview pane.")
            }

            Section {
                Toggle("Don't create .DS_Store files on network drives", isOn: Binding(get: { noNetworkStores }, set: { v in
                    noNetworkStores = v
                    m.perform("Saving…") { Prefs.setBool(Maintenance.desktopServices, "DSDontWriteNetworkStores", v); return "Saved — log out and back in for it to take effect" }
                }))
                Toggle("Don't create .DS_Store files on USB drives", isOn: Binding(get: { noUSBStores }, set: { v in
                    noUSBStores = v
                    m.perform("Saving…") { Prefs.setBool(Maintenance.desktopServices, "DSDontWriteUSBStores", v); return "Saved — log out and back in for it to take effect" }
                }))
            } header: {
                Text("Network and external drives")
            } footer: {
                Text("Stops Finder writing hidden .DS_Store files onto shared and external drives, which makes browsing network shares noticeably faster. Folders on those drives then don't remember their view settings. Takes effect after you log out and back in.")
            }

            Section {
                repairRow("Reset Quick Look", "Fixes missing, blank or stuck previews and thumbnails.", "Reset") {
                    m.perform("Resetting Quick Look…", FinderActions.resetQuickLook)
                }
                repairRow("Restart iCloud Drive syncing", "For iCloud files stuck downloading, or iCloud folders that are slow to open.", "Restart…") {
                    fix = .restartICloud
                }
                repairRow("Restart File Provider", "For cloud folders (OneDrive, Box, Google Drive, Dropbox) that hang Finder or stop syncing.", "Restart…") {
                    fix = .restartFileProvider
                }
                repairRow("Reset Open and Save dialogs", "For Open/Save dialogs that are slow to appear in every app.", "Reset…") {
                    fix = .resetOpenSave
                }
                repairRow("Reset all Finder settings", "Last resort for odd Finder behaviour. Your current settings are backed up first.", "Reset…") {
                    fix = .resetFinderSettings
                }
                if let backup {
                    repairRow("Restore Finder settings", "From the backup \(backup.lastPathComponent).", "Restore…") {
                        fix = .restoreFinderSettings(backup)
                    }
                }
                if !m.actionMessage.isEmpty {
                    Text(m.actionMessage).foregroundStyle(.secondary)
                }
            } header: {
                Text("Repairs")
            } footer: {
                Text("None of these need an administrator password or delete your files. Fixes that are often recommended online but are obsolete or risky on current macOS — rebuilding LaunchServices with -kill, purge, deleting iCloud folders, wiping caches with sudo — are deliberately left out.")
            }

            Section {
                LabeledContent("Spotlight on your Mac", value: spotlight)
                Button("Open Spotlight Settings") { openSystemSettings("com.apple.Spotlight-Settings.extension") }
            } header: {
                Text("Spotlight")
            } footer: {
                Text("If Finder search or Recents never finish, rebuild the index without an administrator password: in Spotlight Settings → Search Privacy, add your disk, wait 30 seconds, then remove it. Rebuilding takes a while and isn't needed for normal indexing activity.")
            }

            Section("System Settings") {
                Button("Open Login Items & Extensions") { openSystemSettings("com.apple.LoginItems-Settings.extension") }
                Button("Open Automation privacy settings") { openSystemSettings("com.apple.preference.security?Privacy_Automation") }
            }
        }
        .formStyle(.grouped)
        .fixConfirmation($fix, monitor: m) { Task { await reload() } }
        .task { await reload() }
    }

    private func repairRow(_ title: String, _ detail: String, _ button: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
    }

    private func applyFinder(_ working: String, _ change: @escaping () -> Void) {
        m.perform(working) {
            change()
            FinderActions.relaunchFinder()
            return "Finder setting updated"
        }
    }

    private func reload() async {
        let finder = Maintenance.finderDomain, ds = Maintenance.desktopServices
        showHidden = await offMain { Prefs.bool(finder, "AppleShowAllFiles") }
        previewPane = await offMain { Prefs.bool(finder, "ShowPreviewPane") }
        newWindow = await offMain {
            Prefs.string(finder, "NewWindowTarget").flatMap(NewWindowTarget.init(rawValue:)) ?? .recents
        }
        noNetworkStores = await offMain { Prefs.bool(ds, "DSDontWriteNetworkStores") }
        noUSBStores = await offMain { Prefs.bool(ds, "DSDontWriteUSBStores") }
        backup = await offMain { Maintenance.latestFinderBackup() }
        spotlight = await offMain { Maintenance.spotlightStatus() }
    }
}
