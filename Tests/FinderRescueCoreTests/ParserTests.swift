import XCTest
@testable import FinderRescueCore

final class LaunchdParserTests: XCTestCase {
    func testLaunchctlList() {
        let text = "PID\tStatus\tLabel\n123\t0\tcom.example.running\n-\t78\tcom.example.failed\n-\t-9\tcom.example.killed\n"
        let jobs = StartupItems.parseLaunchctlList(text)
        XCTAssertEqual(jobs["com.example.running"], StartupItems.Job(pid: 123, status: 0))
        XCTAssertEqual(jobs["com.example.failed"], StartupItems.Job(pid: nil, status: 78))
        XCTAssertEqual(jobs["com.example.killed"]?.status, -9)
    }

    func testPrintDisabled() {
        let text = """
        disabled services = {
        \t"com.example.off" => disabled
        \t"com.example.on" => enabled
        \t"com.example.legacy" => true
        }
        """
        XCTAssertEqual(StartupItems.parseDisabled(text), ["com.example.off", "com.example.legacy"])
    }

    func testSchedules() {
        XCTAssertEqual(StartupItems.schedule(["KeepAlive": true]), "Always running")
        XCTAssertEqual(StartupItems.schedule(["KeepAlive": ["SuccessfulExit": false]]), "Kept alive")
        XCTAssertEqual(StartupItems.schedule(["StartInterval": 120]), "Every 2 min")
        XCTAssertEqual(StartupItems.schedule(["StartInterval": 3600]), "Every 1 h")
        XCTAssertEqual(StartupItems.schedule(["StartCalendarInterval": ["Hour": 18, "Minute": 0]]), "Daily 18:00")
        XCTAssertEqual(StartupItems.schedule(["StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 30]]), "Mon 09:30")
        XCTAssertEqual(StartupItems.schedule(["StartCalendarInterval": [["Hour": 2], ["Hour": 14]]]), "Daily 02:00 (+1)")
        XCTAssertEqual(StartupItems.schedule(["RunAtLoad": true]), "At login")
        XCTAssertEqual(StartupItems.schedule([:]), "On demand")
    }

    func testMissingFiles() {
        let exists: (String) -> Bool = { $0.hasPrefix("/bin/") }
        XCTAssertEqual(StartupItems.missingFile(program: "/nope/tool", args: ["/nope/tool"], exists: exists), "/nope/tool")
        XCTAssertEqual(StartupItems.missingFile(program: "/bin/bash", args: ["/bin/bash", "/nope/job.sh"], exists: exists), "/nope/job.sh")
        XCTAssertNil(StartupItems.missingFile(program: "/bin/bash", args: ["/bin/bash", "-c", "/nope/a.sh ; /nope/b.sh"], exists: exists),
                     "inline commands can't be checked as a single path")
        XCTAssertNil(StartupItems.missingFile(program: "/bin/python3", args: ["/bin/python3", "-m", "tool"], exists: exists))
        XCTAssertNil(StartupItems.missingFile(program: "", args: [], exists: exists))
    }

    func testProblemsOnlyForEnabledItems() {
        let off = LaunchItem(label: "x", path: "/p", scope: .backup, command: "", missingPath: "/gone", schedule: "",
                             pid: nil, lastExit: nil, overrideDisabled: false, loaded: false)
        XCTAssertNil(off.problem)
        let killed = LaunchItem(label: "y", path: "/q", scope: .user, command: "", missingPath: nil, schedule: "",
                                pid: nil, lastExit: 143, overrideDisabled: false, loaded: true)
        XCTAssertNil(killed.problem)
        let failed = LaunchItem(label: "z", path: "/r", scope: .user, command: "", missingPath: nil, schedule: "",
                                pid: nil, lastExit: 1, overrideDisabled: false, loaded: true)
        XCTAssertEqual(failed.problem, "Last run failed (exit 1)")
    }
}

final class PluginkitParserTests: XCTestCase {
    func testParse() {
        let output = """
        +    com.example.a.ext(1.0)
        \t            Path = /Applications/Alpha.app/Contents/PlugIns/A.appex
        \t            UUID = 1234
        -    com.example.b.ext(2.0)
        \t            Path = /Applications/Beta Sync.app/Contents/PlugIns/B.appex
             com.apple.CloudDocs.iCloudDriveFileProvider(1.0)
        \t            Path = /System/Library/PrivateFrameworks/CloudDocsDaemon.framework/PlugIns/X.appex
             (3 plug-ins)
        """
        let exts = Extensions.parse(output, kind: "Cloud storage")
        XCTAssertEqual(exts.map(\.id), ["com.example.a.ext", "com.example.b.ext", "com.apple.CloudDocs.iCloudDriveFileProvider"])
        XCTAssertEqual(exts.map(\.enabled), [true, false, true])
        XCTAssertEqual(exts.map(\.appName), ["Alpha", "Beta Sync", "iCloud Drive"])
        XCTAssertTrue(exts[2].isApple)
    }
}
