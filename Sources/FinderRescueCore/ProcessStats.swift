import Foundation
import Darwin

/// Cheap in-process process statistics via libproc — no helper processes needed.
public enum ProcessStats {
    public static let finderPath = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"

    /// rusage CPU times are in Mach absolute-time units; this converts them to nanoseconds.
    static let ticksToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    public struct Usage: Sendable {
        public let cpuNs: UInt64
        public let footprint: UInt64
        public let bytesWritten: UInt64
    }

    public static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).filter { $0 > 0 }
    }

    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func owner(of pid: pid_t) -> uid_t? {
        bsdInfo(pid)?.pbi_uid
    }

    public static func isFinder(_ pid: pid_t) -> Bool {
        path(of: pid) == finderPath && owner(of: pid) == getuid()
    }

    /// The current user's Finder. Checks `hint` (the last known PID) first to avoid a full scan.
    public static func finderPID(hint: pid_t? = nil) -> pid_t? {
        if let hint, isFinder(hint) { return hint }
        return allPIDs().first(where: isFinder)
    }

    /// PIDs of processes with these short names, preferring ones owned by the current user.
    public static func pids(named names: Set<String>) -> [String: pid_t] {
        let uid = getuid()
        var found: [String: pid_t] = [:]
        for pid in allPIDs() {
            guard let name = name(of: pid), names.contains(name) else { continue }
            if found[name] == nil || owner(of: pid) == uid { found[name] = pid }
        }
        return found
    }

    public static func startDate(_ pid: pid_t) -> Date? {
        guard let info = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    /// Nil when the process is gone or owned by another user (e.g. root daemons).
    public static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(cpuNs: UInt64(Double(ticks) * ticksToNs),
                     footprint: info.ri_phys_footprint,
                     bytesWritten: info.ri_diskio_byteswritten)
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}
