import XCTest
@testable import FinderRescueCore

final class StuckDetectorTests: XCTestCase {
    private let settings = DetectorSettings(cpuThreshold: 85, sustainSeconds: 180, memoryLimitMB: 2500)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// One sample every 5 s, oldest first, ending at `now`.
    private func samples(seconds: Int, cpu: (Int) -> Double, write: Double = 0) -> [Sample] {
        stride(from: seconds, through: 0, by: -5).enumerated().map { index, age in
            Sample(date: now.addingTimeInterval(-Double(age)), cpu: cpu(index), writeMBps: write)
        }
    }

    private func assess(_ s: [Sample], footprint: Double = 300, pings: Int = 0) -> Assessment {
        StuckDetector.assess(samples: s, now: now, footprintMB: footprint, pingFailures: pings,
                             settings: settings, interval: 5)
    }

    func testSustainedHighCPUIsStuck() {
        let a = assess(samples(seconds: 180, cpu: { _ in 100 }))
        XCTAssertNotNil(a.stuckReason)
        XCTAssertFalse(a.copying)
    }

    func testShortSpikeIsNotStuck() {
        XCTAssertNil(assess(samples(seconds: 60, cpu: { _ in 100 })).stuckReason)
    }

    func testSingleDipDoesNotResetTheWindow() {
        let a = assess(samples(seconds: 180, cpu: { $0 == 10 ? 20 : 100 }))
        XCTAssertNotNil(a.stuckReason)
    }

    func testBurstyWorkIsNotStuck() {
        let a = assess(samples(seconds: 180, cpu: { $0.isMultiple(of: 2) ? 100 : 10 }))
        XCTAssertNil(a.stuckReason)
        XCTAssertFalse(a.busy == false && a.stuckReason != nil)
    }

    func testCopyingIsFlagged() {
        let a = assess(samples(seconds: 180, cpu: { _ in 100 }, write: 25))
        XCTAssertTrue(a.copying)
        XCTAssertNotNil(a.stuckReason, "the reason is still reported; the monitor decides to hold off")
    }

    func testRepeatedPingFailuresAreStuck() {
        let a = assess(samples(seconds: 30, cpu: { _ in 5 }), pings: 3)
        XCTAssertEqual(a.stuckReason?.hasPrefix("Not responding"), true)
    }

    func testTwoPingFailuresAreNotEnough() {
        XCTAssertNil(assess(samples(seconds: 30, cpu: { _ in 5 }), pings: 2).stuckReason)
    }

    func testMemoryLimit() {
        let a = assess(samples(seconds: 30, cpu: { _ in 5 }), footprint: 3000)
        XCTAssertEqual(a.stuckReason, "Using 2.9 GB of memory")
    }

    func testIdleIsHealthy() {
        let a = assess(samples(seconds: 180, cpu: { _ in 1 }))
        XCTAssertNil(a.stuckReason)
        XCTAssertFalse(a.busy)
        XCTAssertFalse(a.copying)
    }

    func testNoSamples() {
        let a = assess([])
        XCTAssertNil(a.stuckReason)
        XCTAssertFalse(a.busy)
    }
}

final class VersionTests: XCTestCase {
    func testComparison() {
        XCTAssertTrue(Version.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(Version.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertEqual(Version.normalize("v2.3.4"), "2.3.4")
    }
}

final class FormatTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Fmt.mb(512), "512 MB")
        XCTAssertEqual(Fmt.mb(2048), "2.0 GB")
        XCTAssertEqual(Fmt.minutes(1), "1 minute")
        XCTAssertEqual(Fmt.minutes(3), "3 minutes")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Fmt.uptime(now.addingTimeInterval(-90_000), now: now), "1 d 1 h")
        XCTAssertEqual(Fmt.uptime(nil), "—")
    }
}
