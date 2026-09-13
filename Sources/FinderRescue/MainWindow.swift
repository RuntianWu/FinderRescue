import SwiftUI
import AppKit
import FinderRescueCore

struct MainView: View {
    var body: some View {
        TabView {
            OverviewTab().tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.33percent") }
            RescueSettingsTab().tabItem { Label("Auto-Rescue", systemImage: "lifepreserver") }
            FixesTab().tabItem { Label("Fixes", systemImage: "wrench.and.screwdriver") }
            StartupTab().tabItem { Label("Startup Items", systemImage: "power") }
            ExtensionsTab().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            LogTab().tabItem { Label("Rescue Log", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 880, minHeight: 580)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @EnvironmentObject var m: FinderMonitor
    @State private var fix: Fix?

    var body: some View {
        Form {
            Section("Finder") {
                StatusHeader()
                if m.health == .pending, let due = m.pendingRescueAt {
                    PendingBanner(due: due)
                }
                MetricsRow()
                Sparkline(values: m.history, threshold: m.cpuThreshold).frame(height: 70)
                if !m.pingNote.isEmpty {
                    HStack {
                        Text(m.pingNote).font(.caption).foregroundStyle(.secondary)
                        Button("Open Settings") { openSystemSettings("com.apple.preference.security?Privacy_Automation") }
                            .font(.caption)
                    }
                }
            }
            Section("Quick fixes") {
                HStack {
                    Button("Relaunch Finder") { m.rescue(reason: "Relaunched manually", automatic: false) }
                    Button("Close search windows") { m.perform("Closing search windows…", FinderActions.closeSearchWindows) }
                    Button("Reset Quick Look") { m.perform("Resetting Quick Look…", FinderActions.resetQuickLook) }
                }
                if !m.actionMessage.isEmpty {
                    Text(m.actionMessage).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(m.services) { service in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.title)
                            Text(service.pid.map { "\(service.id) · PID " + String($0) } ?? "\(service.id) · not running")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(service.cpu.map { "\(Int($0.rounded()))% CPU" } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle((service.cpu ?? 0) >= 80 ? .orange : .secondary)
                        if service.restartable {
                            Button("Restart") {
                                fix = service.id == "bird" ? .restartICloud : .restartFileProvider
                            }
                            .disabled(service.pid == nil)
                        }
                    }
                }
            } header: {
                Text("Background services Finder depends on")
            } footer: {
                Text("Cloud syncing (File Provider, iCloud Drive) and Spotlight are the most common reasons Finder slows down on recent macOS. A service that stays at high CPU for a long time is worth restarting — it starts again by itself.")
            }
            Section {
                if m.mounts.isEmpty {
                    Text("No network drives are connected.").foregroundStyle(.secondary)
                } else {
                    ForEach(m.mounts) { mount in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mount.path)
                                Text("\(mount.type) · \(mount.source)").font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            switch mount.responsive {
                            case .some(true): Text("Responding").foregroundStyle(.secondary)
                            case .some(false): Text("Not responding").foregroundStyle(.orange)
                            case .none: Text("Checking…").foregroundStyle(.secondary)
                            }
                            Button("Disconnect") { fix = .forceUnmount(mount) }
                        }
                    }
                }
                Button("Check again") { m.checkMounts() }
            } header: {
                Text("Network drives")
            } footer: {
                Text("A network share whose server has gone away can freeze Finder. Drives are checked every minute; disconnecting a dead one usually unfreezes Finder immediately.")
            }
        }
        .formStyle(.grouped)
        .fixConfirmation($fix, monitor: m) { m.checkMounts() }
    }
}

// MARK: - Auto-Rescue settings

struct RescueSettingsTab: View {
    @EnvironmentObject var m: FinderMonitor
    @EnvironmentObject var prefs: AppPreferences
    @EnvironmentObject var updates: UpdateChecker
    @State private var loginItem = LaunchAtLogin.isEnabled
    @State private var loginNote: String?

    var body: some View {
        Form {
            Section {
                Picker("When Finder gets stuck", selection: $m.mode) {
                    ForEach(RescueMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                Toggle("Warn 30 seconds before relaunching, with a chance to cancel", isOn: $m.warnBeforeRescue)
                    .disabled(m.mode != .auto)
                if m.isSnoozed, let until = m.snoozedUntil {
                    HStack {
                        Text("Paused until \(Fmt.time.string(from: until))").foregroundStyle(.secondary)
                        Button("Resume now") { m.resumeAutoRescue() }
                    }
                }
            }
            Section {
                Stepper(value: $m.cpuThreshold, in: 50...150, step: 5) {
                    LabeledContent("CPU threshold", value: "\(Int(m.cpuThreshold))%")
                }
                Stepper(value: $m.sustainMinutes, in: 1...15, step: 1) {
                    LabeledContent("…for at least", value: Fmt.minutes(m.sustainMinutes))
                }
                Toggle("Check that Finder responds (every 20 seconds)", isOn: $m.pingEnabled)
                Stepper(value: $m.memoryLimitMB, in: 1000...8000, step: 250) {
                    LabeledContent("Memory limit", value: Fmt.mb(m.memoryLimitMB))
                }
            } header: {
                Text("What counts as stuck")
            } footer: {
                Text("Finder counts as stuck if any of these happens: its CPU stays above the threshold for the whole period; it doesn't answer, or takes more than 5 seconds to answer, three checks in a row (about a minute); or its memory grows past the limit. A stuck Finder usually sits at about 100% CPU. Rescue always waits while Finder is copying files, so copies are never interrupted.")
            }
            Section("Rescue") {
                Stepper(value: $m.cooldownMinutes, in: 5...120, step: 5) {
                    LabeledContent("Wait between rescues", value: Fmt.minutes(m.cooldownMinutes))
                }
                Toggle("Save a diagnostic sample before relaunching", isOn: $m.captureSample)
            }
            Section("App") {
                Toggle("Open Finder Rescue at login", isOn: Binding(get: { loginItem }, set: { v in
                    do {
                        try LaunchAtLogin.set(v)
                        loginNote = LaunchAtLogin.status == .requiresApproval
                            ? "Approve Finder Rescue in System Settings → General → Login Items." : nil
                    } catch {
                        loginNote = error.localizedDescription
                    }
                    loginItem = LaunchAtLogin.isEnabled
                }))
                if let loginNote {
                    Text(loginNote).font(.caption).foregroundStyle(.orange)
                }
                Toggle("\(HotKey.displayString) relaunches Finder from any app", isOn: $prefs.hotKeyEnabled)
                if prefs.hotKeyEnabled && !HotKey.shared.isRegistered {
                    Text("Another app is already using \(HotKey.displayString).").font(.caption).foregroundStyle(.orange)
                }
                Toggle("Check for updates automatically", isOn: $prefs.autoCheckForUpdates)
                HStack {
                    Button(updates.isChecking ? "Checking…" : "Check for Updates Now") {
                        Task { await updates.checkNow(userInitiated: true) }
                    }
                    .disabled(updates.isChecking)
                    if let checked = updates.lastChecked {
                        Text("Last checked \(Fmt.dateTime.string(from: checked))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modeExplanation: String {
        switch m.mode {
        case .off: return "Finder is still monitored and shown in the menu bar, but nothing happens when it gets stuck."
        case .notify: return "You get a notification with a Relaunch Finder button when Finder gets stuck."
        case .auto: return "Finder is relaunched automatically when it gets stuck. You get a notification either way."
        }
    }
}
