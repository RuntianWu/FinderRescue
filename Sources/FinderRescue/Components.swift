import SwiftUI
import AppKit
import FinderRescueCore

struct StatusHeader: View {
    @EnvironmentObject var m: FinderMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(m.health.color).frame(width: 10, height: 10)
                Text(m.health.title).font(.headline)
                Spacer()
            }
            if let reason = m.stuckReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            if m.isSnoozed, let until = m.snoozedUntil {
                HStack(spacing: 6) {
                    Text("Auto-rescue paused until \(Fmt.time.string(from: until))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resume") { m.resumeAutoRescue() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

/// Countdown shown while an automatic relaunch is pending, with the two ways out.
struct PendingBanner: View {
    @EnvironmentObject var m: FinderMonitor
    let due: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(.orange)
                Text("Relaunching Finder in \(max(0, Int(due.timeIntervalSince(context.date).rounded(.up)))) s")
                    .monospacedDigit()
                Spacer()
                Button("Not Now") { m.snooze() }
                Button("Relaunch Now") { m.rescue(reason: m.stuckReason ?? "Relaunched manually", automatic: false) }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct MetricsRow: View {
    @EnvironmentObject var m: FinderMonitor

    var body: some View {
        HStack(spacing: 0) {
            Metric(title: "CPU", value: "\(Int(m.cpu.rounded()))%")
            Metric(title: "Memory", value: Fmt.mb(m.footprintMB))
            Metric(title: "Running for", value: Fmt.uptime(m.launchDate))
            Metric(title: "Responding", value: m.responsivenessText)
                .help(m.pingLatency.map { "Last answer took \(Fmt.seconds($0))" } ?? "")
        }
    }
}

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).monospacedDigit()).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Finder CPU over the last ~6 minutes, with the stuck threshold dashed.
struct Sparkline: View {
    let values: [Double]
    let threshold: Double

    var body: some View {
        GeometryReader { g in
            let top = max(threshold * 1.25, values.max() ?? 0, 10)
            let y: (Double) -> CGFloat = { g.size.height * (1 - CGFloat(min($0, top) / top)) }
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(threshold)))
                    p.addLine(to: CGPoint(x: g.size.width, y: y(threshold)))
                }
                .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .accessibilityLabel("Finder CPU over the last few minutes")
    }
}

struct ActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }
}

struct WarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
    }
}

// MARK: - Fixes that need a confirmation

struct Fix: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let progress: String
    var destructive = false
    let work: () -> String

    static let restartFileProvider = Fix(
        title: "Restart File Provider?",
        message: "Restarts fileproviderd, the service behind OneDrive, Box, Google Drive, Dropbox and iCloud Drive folders in Finder. Syncing pauses for a moment and then carries on. Nothing is deleted.",
        confirmLabel: "Restart", progress: "Restarting File Provider…",
        work: { Maintenance.restartService("fileproviderd", title: "File Provider") })

    static let restartICloud = Fix(
        title: "Restart iCloud Drive syncing?",
        message: "Restarts bird, the iCloud Drive sync service. Use it when iCloud files are stuck downloading or syncing. Nothing is deleted.",
        confirmLabel: "Restart", progress: "Restarting iCloud Drive…",
        work: { Maintenance.restartService("bird", title: "iCloud Drive") })

    static let resetOpenSave = Fix(
        title: "Reset the Open and Save dialogs?",
        message: "Clears the remembered size, view and last-used folder of Open and Save dialogs in all apps. Use it when those dialogs are slow to appear or show a blank list.",
        confirmLabel: "Reset", progress: "Resetting Open and Save dialogs…",
        work: Maintenance.resetOpenSavePanel)

    static let resetFinderSettings = Fix(
        title: "Reset all Finder settings?",
        message: "Finder Rescue first saves a backup of your Finder settings, then returns every Finder setting (views, sidebar, toolbar, new-window folder, hidden files…) to the default and relaunches Finder. You can restore the backup from this tab.",
        confirmLabel: "Back Up and Reset", progress: "Backing up and resetting Finder settings…",
        destructive: true, work: Maintenance.resetFinderPrefs)

    static func restoreFinderSettings(_ url: URL) -> Fix {
        Fix(title: "Restore Finder settings?",
            message: "Replaces your current Finder settings with the backup from \(url.lastPathComponent) and relaunches Finder.",
            confirmLabel: "Restore", progress: "Restoring Finder settings…",
            work: { Maintenance.restoreFinderPrefs(from: url) })
    }

    static func forceUnmount(_ mount: NetworkMount) -> Fix {
        Fix(title: "Disconnect \(mount.path)?",
            message: "Force-disconnects the network share \(mount.source). Unsaved changes to files on it may be lost. Finder usually recovers as soon as the dead share is gone.",
            confirmLabel: "Disconnect", progress: "Disconnecting \(mount.path)…",
            destructive: true, work: { Maintenance.forceUnmount(mount) })
    }
}

private struct FixConfirmation: ViewModifier {
    @Binding var fix: Fix?
    let monitor: FinderMonitor
    let completion: () -> Void

    func body(content: Content) -> some View {
        content.alert(fix?.title ?? "", isPresented: Binding(get: { fix != nil }, set: { if !$0 { fix = nil } }),
                      presenting: fix) { f in
            Button(f.confirmLabel, role: f.destructive ? .destructive : nil) {
                monitor.perform(f.progress) {
                    let message = f.work()
                    DispatchQueue.main.async(execute: completion)
                    return message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text(f.message)
        }
    }
}

extension View {
    func fixConfirmation(_ fix: Binding<Fix?>, monitor: FinderMonitor, completion: @escaping () -> Void = {}) -> some View {
        modifier(FixConfirmation(fix: fix, monitor: monitor, completion: completion))
    }
}

func openSystemSettings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:" + anchor) { NSWorkspace.shared.open(url) }
}
