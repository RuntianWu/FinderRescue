import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
    public let timedOut: Bool
    public var ok: Bool { status == 0 && !timedOut }
}

public enum Shell {
    /// Runs a command synchronously — call it off the main thread. After `timeout` seconds the
    /// command is terminated; if it can't be killed (e.g. stuck in the kernel on a dead network
    /// mount) it is abandoned rather than blocking the caller forever.
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return ShellResult(status: -1, out: "", err: error.localizedDescription, timedOut: false)
        }

        // Drain both pipes concurrently so a chatty command can't fill a pipe and block.
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.setOut(outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.setErr(errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }

        var timedOut = false
        if !waitForExit(process, until: Date().addingTimeInterval(timeout)) {
            timedOut = true
            process.terminate()
            if !waitForExit(process, until: Date().addingTimeInterval(1)) {
                kill(process.processIdentifier, SIGKILL)
                if !waitForExit(process, until: Date().addingTimeInterval(1)) {
                    return ShellResult(status: -2, out: "", err: "Timed out", timedOut: true)
                }
            }
        }
        _ = group.wait(timeout: .now() + 2)
        return ShellResult(status: process.terminationStatus, out: box.outString, err: box.errString, timedOut: timedOut)
    }

    public static func osascript(_ lines: [String], timeout: TimeInterval = 15) -> ShellResult {
        run("/usr/bin/osascript", lines.flatMap { ["-e", $0] }, timeout: timeout)
    }

    private static func waitForExit(_ process: Process, until deadline: Date) -> Bool {
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOut(_ data: Data) { lock.lock(); out = data; lock.unlock() }
    func setErr(_ data: Data) { lock.lock(); err = data; lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

/// Runs blocking work on a background queue and returns its result.
public func offMain<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
