import SwiftUI
import AppKit
import FinderRescueCore

struct MenuContent: View {
    @EnvironmentObject var m: FinderMonitor
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader()
            if m.health == .pending, let due = m.pendingRescueAt {
                PendingBanner(due: due)
            }
            MetricsRow()
            Sparkline(values: m.history, threshold: m.cpuThreshold).frame(height: 40)

            let hot = m.hotServices
            let deadMounts = m.stuckMounts
            if !hot.isEmpty || !deadMounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hot) { WarningRow(text: "\($0.title) is using \(Int($0.cpu ?? 0))% CPU") }
                    ForEach(deadMounts) { WarningRow(text: "Network drive \($0.path) isn't responding") }
                    Button("Show details…") { open(AppWindow.main) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if !m.actionMessage.isEmpty {
                Text(m.actionMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            VStack(spacing: 2) {
                ActionRow("Relaunch Finder", "arrow.clockwise") { m.rescue(reason: "Relaunched manually", automatic: false) }
                ActionRow("Close search windows", "magnifyingglass") { m.perform("Closing search windows…", FinderActions.closeSearchWindows) }
                ActionRow("Reset Quick Look", "eye") { m.perform("Resetting Quick Look…", FinderActions.resetQuickLook) }
            }
            Text("Tip: \(HotKey.displayString) relaunches Finder from anywhere.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("When Finder gets stuck").font(.caption).foregroundStyle(.secondary)
                Picker("When Finder gets stuck", selection: $m.mode) {
                    ForEach(RescueMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let update = updates.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    Label("Finder Rescue \(update.version) is available", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.link)
            }

            HStack {
                Button("Open Finder Rescue…") { open(AppWindow.main) }
                Spacer()
                Button("About") { open(AppWindow.about) }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
