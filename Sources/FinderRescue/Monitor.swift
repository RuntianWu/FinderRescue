import Foundation
import AppKit
import SwiftUI
import UserNotifications
import FinderRescueCore

enum RescueMode: Int, CaseIterable, Identifiable {
    case off, notify, auto
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .notify: return "Notify"
        case .auto: return "Auto-rescue"
        }
    }
}

enum FinderHealth: Equatable {
    case ok, busy, copying, stuck, pending, notRunning, rescuing

    var title: String {
        switch self {
        case .ok: return "Finder is healthy"
        case .busy: return "Finder is busy"
        case .copying: return "Finder is copying files"
        case .stuck: return "Finder looks stuck"
        case .pending: return "Finder looks stuck — relaunching soon"
        case .notRunning: return "Finder isn't running"
        case .rescuing: return "Rescuing Finder…"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .busy, .copying: return .yellow
        case .stuck, .pending, .notRunning: return .red
        case .rescuing: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "waveform.path.ecg"
        case .busy, .copying: return "waveform.path.ecg.rectangle"
        case .stuck, .pending, .notRunning: return "exclamationmark.triangle.fill"
        case .rescuing: return "arrow.clockwise.circle"
        }
    }
}

/// A background service that commonly slows Finder down, with its recent CPU use.
struct ServiceStat: Identifiable, Equatable {
    let id: String
    let title: String
    let restartable: Bool
    var pid: pid_t? = nil
    var cpu: Double? = nil
}

/// Samples Finder every 5 s and decides when to rescue it.
///
/// The decision itself lives in `StuckDetector` (unit-tested). This class feeds it samples, runs the
/// responsiveness check, and turns a verdict into an action according to the chosen mode — with a
/// 30-second warning (cancellable from the notification) before an automatic relaunch.
@MainActor
final class FinderMonitor: ObservableObject {
    static let shared = FinderMonitor()

    static let watchedServices = [
        ServiceStat(id: "fileproviderd", title: "File Provider (cloud folders)", restartable: true),
        ServiceStat(id: "bird", title: "iCloud Drive", restartable: true),
        ServiceStat(id: "cloudd", title: "CloudKit", restartable: false),
        ServiceStat(id: "mds_stores", title: "Spotlight indexing", restartable: false),
    ]
    static let pendingNotificationID = "pending-rescue"

    // MARK: Live state

    @Published private(set) var pid: pid_t?
    @Published private(set) var cpu: Double = 0
    @Published private(set) var footprintMB: Double = 0
    @Published private(set) var launchDate: Date?
    @Published private(set) var responsive: Bool?
    @Published private(set) var pingLatency: Double?
    @Published private(set) var pingNote = ""
    @Published private(set) var health: FinderHealth = .ok
    @Published private(set) var stuckReason: String?
    @Published private(set) var pendingRescueAt: Date?
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var history: [Double] = []
    @Published private(set) var services: [ServiceStat] = FinderMonitor.watchedServices
    @Published private(set) var mounts: [NetworkMount] = []
    @Published private(set) var events: [RescueEvent] = []
    @Published var actionMessage = ""

    // MARK: Settings

    @Published var mode: RescueMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode); if mode != .auto { cancelPending() } } }
    @Published var cpuThreshold: Double { didSet { defaults.set(cpuThreshold, forKey: Keys.cpu) } }
    @Published var sustainMinutes: Double { didSet { defaults.set(sustainMinutes, forKey: Keys.sustain) } }
    @Published var memoryLimitMB: Double { didSet { defaults.set(memoryLimitMB, forKey: Keys.memory) } }
    @Published var cooldownMinutes: Double { didSet { defaults.set(cooldownMinutes, forKey: Keys.cooldown) } }
    @Published var captureSample: Bool { didSet { defaults.set(captureSample, forKey: Keys.sample) } }
    @Published var warnBeforeRescue: Bool { didSet { defaults.set(warnBeforeRescue, forKey: Keys.warn) } }
    @Published var pingEnabled: Bool {
        didSet {
            defaults.set(pingEnabled, forKey: Keys.ping)
            if !pingEnabled { responsive = nil; pingLatency = nil; pingFailures = 0; pingNote = "" }
        }
    }

    let interval: TimeInterval = 5
    let pingInterval: TimeInterval = 20
    let graceSeconds: TimeInterval = 30
    let slowPingSeconds: Double = 5
    let snoozeMinutes: Double = 30

    private enum Keys {
        static let mode = "mode", cpu = "cpuThreshold", sustain = "sustainMinutes", memory = "memoryLimitMB"
        static let ping = "pingEnabled", cooldown = "cooldownMinutes", sample = "captureSample", warn = "warnBeforeRescue"
    }

    private let defaults = UserDefaults.standard
    private var samples: [Sample] = []
    private var last: (date: Date, cpuNs: UInt64, written: UInt64)?
    private var serviceLast: [pid_t: (date: Date, cpuNs: UInt64)] = [:]
    private var pingFailures = 0
    private var pingInFlight = false
    private var mountCheckInFlight = false
    private var lastPing = Date.distantPast
    private var alertedThisEpisode = false
    private var tickCount = 0
    private var timer: Timer?

    init() {
        defaults.register(defaults: [
            Keys.mode: RescueMode.auto.rawValue, Keys.cpu: 85.0, Keys.sustain: 3.0, Keys.memory: 2500.0,
            Keys.ping: true, Keys.cooldown: 10.0, Keys.sample: true, Keys.warn: true,
        ])
        mode = RescueMode(rawValue: defaults.integer(forKey: Keys.mode)) ?? .auto
        cpuThreshold = defaults.double(forKey: Keys.cpu)
        sustainMinutes = defaults.double(forKey: Keys.sustain)
        memoryLimitMB = defaults.double(forKey: Keys.memory)
        pingEnabled = defaults.bool(forKey: Keys.ping)
        cooldownMinutes = defaults.double(forKey: Keys.cooldown)
        captureSample = defaults.bool(forKey: Keys.sample)
        warnBeforeRescue = defaults.bool(forKey: Keys.warn)
        events = RescueLog.load()
    }

    var lastRescue: Date? { events.first?.date }
    var hotServices: [ServiceStat] { services.filter { ($0.cpu ?? 0) >= 80 } }
    var stuckMounts: [NetworkMount] { mounts.filter { $0.responsive == false } }
    var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } ?? false }

    var responsivenessText: String {
        guard pingEnabled else { return "Off" }
        guard let responsive else { return "—" }
        if responsive { return "Yes" }
        return pingLatency != nil ? "Slow" : "No"
    }

    private var detectorSettings: DetectorSettings {
        DetectorSettings(cpuThreshold: cpuThreshold, sustainSeconds: sustainMinutes * 60, memoryLimitMB: memoryLimitMB)
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Sampling

    private func tick() {
        tickCount += 1
        let now = Date()
        sampleFinder(now)
        if tickCount % 2 == 1 { sampleServices(now) }
        if tickCount % 12 == 1 { checkMounts() }
        if let snoozedUntil, now >= snoozedUntil { self.snoozedUntil = nil }
        if pingEnabled, pid != nil, !pingInFlight, now.timeIntervalSince(lastPing) >= pingInterval { ping() }
        evaluate(now)
    }

    private func sampleFinder(_ now: Date) {
        guard let p = ProcessStats.finderPID(hint: pid) else {
            pid = nil
            last = nil
            samples.removeAll()
            cpu = 0
            return
        }
        if p != pid {
            pid = p
            last = nil
            samples.removeAll()
            pingFailures = 0
            launchDate = ProcessStats.startDate(p)
        }
        guard let u = ProcessStats.usage(p) else { return }
        footprintMB = Double(u.footprint) / 1_048_576

        if let last {
            let wall = now.timeIntervalSince(last.date)
            if wall > interval * 4 {
                samples.removeAll() // The Mac was asleep; start the window over.
            } else if wall > 0.5 {
                let cpuDelta = u.cpuNs >= last.cpuNs ? u.cpuNs - last.cpuNs : 0
                let writeDelta = u.bytesWritten >= last.written ? u.bytesWritten - last.written : 0
                cpu = Double(cpuDelta) / 1e9 / wall * 100
                samples.append(Sample(date: now, cpu: cpu, writeMBps: Double(writeDelta) / 1_048_576 / wall))
                history.append(cpu)
                if history.count > 72 { history.removeFirst(history.count - 72) }
            }
        }
        last = (now, u.cpuNs, u.bytesWritten)
        let keepFrom = now.addingTimeInterval(-sustainMinutes * 60 - interval)
        samples.removeAll { $0.date < keepFrom }
    }

    private func sampleServices(_ now: Date) {
        let found = ProcessStats.pids(named: Set(Self.watchedServices.map(\.id)))
        var seen = Set<pid_t>()
        services = Self.watchedServices.map { base in
            var stat = base
            stat.pid = found[base.id]
            if let p = stat.pid, let u = ProcessStats.usage(p) {
                seen.insert(p)
                if let prev = serviceLast[p] {
                    let wall = now.timeIntervalSince(prev.date)
                    if wall > 0.5 && wall < interval * 8 {
                        let delta = u.cpuNs >= prev.cpuNs ? u.cpuNs - prev.cpuNs : 0
                        stat.cpu = Double(delta) / 1e9 / wall * 100
                    }
                }
                serviceLast[p] = (now, u.cpuNs)
            }
            return stat
        }
        serviceLast = serviceLast.filter { seen.contains($0.key) }
    }

    func checkMounts() {
        guard !mountCheckInFlight else { return }
        mountCheckInFlight = true
        DispatchQueue.global(qos: .utility).async {
            var found = Maintenance.networkMounts()
            for i in found.indices { found[i].responsive = Maintenance.probe(found[i]) }
            DispatchQueue.main.async {
                self.mounts = found
                self.mountCheckInFlight = false
            }
        }
    }

    // MARK: - Decision

    private func evaluate(_ now: Date) {
        guard health != .rescuing else { return }
        guard pid != nil else {
            health = .notRunning
            stuckReason = nil
            cancelPending()
            return
        }

        let assessment = StuckDetector.assess(samples: samples, now: now, footprintMB: footprintMB,
                                              pingFailures: pingEnabled ? pingFailures : 0,
                                              settings: detectorSettings, interval: interval)
        guard let reason = assessment.stuckReason else {
            stuckReason = nil
            alertedThisEpisode = false
            cancelPending()
            health = assessment.copying ? .copying : (assessment.busy ? .busy : .ok)
            return
        }
        if assessment.copying {
            // Finder copies in-process; relaunching would abort the copy.
            cancelPending()
            health = .copying
            stuckReason = reason + " — waiting because Finder is copying files"
            return
        }

        stuckReason = reason
        if isSnoozed {
            health = .stuck
            return
        }
        switch mode {
        case .off:
            health = .stuck
        case .notify:
            health = .stuck
            if !alertedThisEpisode {
                alertedThisEpisode = true
                notify(title: "Finder looks stuck", body: reason + ".", category: "STUCK")
            }
        case .auto:
            if let lastRescue, now.timeIntervalSince(lastRescue) < cooldownMinutes * 60 {
                health = .stuck
                if !alertedThisEpisode {
                    alertedThisEpisode = true
                    notify(title: "Finder is still stuck",
                           body: "It was relaunched less than \(Fmt.minutes(cooldownMinutes)) ago, so Finder Rescue is waiting before trying again.",
                           category: "STUCK")
                }
            } else if !warnBeforeRescue {
                rescue(reason: reason, automatic: true)
            } else if let due = pendingRescueAt {
                if now >= due { rescue(reason: reason, automatic: true) } else { health = .pending }
            } else {
                pendingRescueAt = now.addingTimeInterval(graceSeconds)
                health = .pending
                notify(title: "Finder looks stuck",
                       body: "\(reason). Finder will be relaunched in \(Int(graceSeconds)) seconds.",
                       category: "PENDING", identifier: Self.pendingNotificationID)
            }
        }
    }

    private func cancelPending() {
        guard pendingRescueAt != nil else { return }
        pendingRescueAt = nil
        if health == .pending { health = .stuck }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pendingNotificationID])
    }

    /// Pauses automatic rescue (the "Not Now" button).
    func snooze() {
        let until = Date().addingTimeInterval(snoozeMinutes * 60)
        snoozedUntil = until
        cancelPending()
        actionMessage = "Auto-rescue paused until \(Fmt.time.string(from: until))"
    }

    func resumeAutoRescue() {
        snoozedUntil = nil
        actionMessage = "Auto-rescue resumed"
    }

    // MARK: - Responsiveness check

    private func ping() {
        pingInFlight = true
        lastPing = Date()
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let r = Shell.osascript([
                "with timeout of 10 seconds",
                "tell application \"Finder\" to count Finder windows",
                "end timeout",
            ], timeout: 13)
            let latency = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.handlePing(r, latency: latency) }
        }
    }

    private func handlePing(_ r: ShellResult, latency: Double) {
        pingInFlight = false
        guard pingEnabled else { return }
        if r.ok {
            pingNote = ""
            pingLatency = latency
            // A slow answer is how a Finder that's "gradually getting stuck" first shows up.
            if latency > slowPingSeconds {
                responsive = false
                pingFailures += 1
            } else {
                responsive = true
                pingFailures = 0
            }
        } else if r.err.contains("-1743") || r.err.localizedCaseInsensitiveContains("not authori") {
            responsive = nil
            pingLatency = nil
            pingFailures = 0
            pingNote = "To check that Finder responds, allow Finder Rescue to control Finder in System Settings → Privacy & Security → Automation."
        } else if r.timedOut || r.err.contains("-1712") {
            responsive = false
            pingLatency = nil
            pingFailures += 1
            pingNote = ""
        } else {
            // Other errors (e.g. Finder mid-relaunch) say nothing about a hang.
            responsive = nil
        }
    }

    // MARK: - Actions

    func rescue(reason: String, automatic: Bool) {
        guard health != .rescuing else { return }
        let target = pid
        let cpuNow = cpu, memNow = footprintMB
        let wantSample = captureSample && (automatic || cpuNow >= 50)
        cancelPending()
        health = .rescuing
        actionMessage = wantSample ? "Saving a diagnostic sample, then relaunching Finder…" : "Relaunching Finder…"
        DispatchQueue.global(qos: .userInitiated).async {
            var samplePath: String?
            if wantSample, let target { samplePath = RescueLog.captureSample(pid: target) }
            FinderActions.relaunchFinder()
            let event = RescueEvent(date: Date(), reason: reason, automatic: automatic,
                                    cpu: cpuNow, footprintMB: memNow, samplePath: samplePath)
            RescueLog.append(event)
            DispatchQueue.main.async {
                self.events.insert(event, at: 0)
                self.health = .ok
                self.stuckReason = nil
                self.alertedThisEpisode = false
                self.pingFailures = 0
                self.samples.removeAll()
                self.last = nil
                self.pid = nil
                self.actionMessage = automatic ? "Finder was rescued automatically" : "Finder relaunched"
                if automatic {
                    self.notify(title: "Finder was rescued", body: reason + ". Finder has been relaunched.")
                }
            }
        }
    }

    /// Runs a blocking fix in the background and shows its result message.
    func perform(_ working: String, _ work: @escaping () -> String) {
        actionMessage = working
        DispatchQueue.global(qos: .userInitiated).async {
            let message = work()
            DispatchQueue.main.async { self.actionMessage = message }
        }
    }

    func clearLog() {
        RescueLog.clear()
        events = []
    }

    func notify(title: String, body: String, category: String? = nil,
                identifier: String = UUID().uuidString, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
