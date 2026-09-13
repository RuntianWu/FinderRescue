import Foundation

public struct DetectorSettings: Sendable, Equatable {
    /// Percent of one core (a stuck main thread shows ~100%).
    public var cpuThreshold: Double
    public var sustainSeconds: TimeInterval
    public var memoryLimitMB: Double
    /// Consecutive failed or slow responsiveness checks that count as a hang.
    public var pingFailuresToTrip: Int
    /// Average disk-write rate above which Finder is considered to be copying.
    public var copyingMBps: Double

    public init(cpuThreshold: Double, sustainSeconds: TimeInterval, memoryLimitMB: Double,
                pingFailuresToTrip: Int = 3, copyingMBps: Double = 3) {
        self.cpuThreshold = cpuThreshold
        self.sustainSeconds = sustainSeconds
        self.memoryLimitMB = memoryLimitMB
        self.pingFailuresToTrip = pingFailuresToTrip
        self.copyingMBps = copyingMBps
    }
}

public struct Sample: Sendable, Equatable {
    public let date: Date
    public let cpu: Double
    public let writeMBps: Double

    public init(date: Date, cpu: Double, writeMBps: Double) {
        self.date = date
        self.cpu = cpu
        self.writeMBps = writeMBps
    }
}

public struct Assessment: Sendable, Equatable {
    /// Why Finder counts as stuck, or nil if it doesn't.
    public let stuckReason: String?
    /// Finder is writing to disk — probably copying, so it must not be relaunched.
    public let copying: Bool
    public let busy: Bool
}

/// Pure decision logic, kept separate from sampling so it can be unit-tested.
///
/// Finder counts as stuck when any of these holds:
/// - CPU at or above the threshold for ≥ 90% of samples spanning the whole sustain window
///   (a single dip doesn't reset it, but ordinary bursty work does),
/// - the responsiveness check failed or was slow several times in a row,
/// - its memory footprint is past the limit.
public enum StuckDetector {
    public static func assess(samples: [Sample], now: Date, footprintMB: Double, pingFailures: Int,
                              settings: DetectorSettings, interval: TimeInterval) -> Assessment {
        let recent = samples.filter { now.timeIntervalSince($0.date) <= 30 }
        let copying = !recent.isEmpty
            && recent.map(\.writeMBps).reduce(0, +) / Double(recent.count) > settings.copyingMBps

        var reason: String?
        let window = samples.filter { now.timeIntervalSince($0.date) <= settings.sustainSeconds }
        if window.count >= 3, let first = window.first,
           now.timeIntervalSince(first.date) >= settings.sustainSeconds - interval * 1.5 {
            let hot = window.filter { $0.cpu >= settings.cpuThreshold }.count
            if Double(hot) >= Double(window.count) * 0.9 {
                reason = "CPU above \(Int(settings.cpuThreshold))% for \(Fmt.minutes(settings.sustainSeconds / 60))"
            }
        }
        if pingFailures >= settings.pingFailuresToTrip {
            reason = "Not responding (\(pingFailures) checks in a row failed or were slow)"
        }
        if footprintMB >= settings.memoryLimitMB {
            reason = "Using \(Fmt.mb(footprintMB)) of memory"
        }
        return Assessment(stuckReason: reason, copying: copying, busy: (samples.last?.cpu ?? 0) >= 50)
    }
}
