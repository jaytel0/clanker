import XCTest
@testable import Clanker

final class ProcessSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesProcessLineWithAllColumns() {
        let line = "  812   799   812   812 S+    12.5 01:02:03 ttys004 /bin/zsh -il"
        let row = ProcessSnapshot.parseProcessLine(line[...], now: now)

        XCTAssertEqual(row?.pid, 812)
        XCTAssertEqual(row?.ppid, 799)
        XCTAssertEqual(row?.pgid, 812)
        XCTAssertEqual(row?.tpgid, 812)
        XCTAssertEqual(row?.stat, "S+")
        XCTAssertEqual(row?.cpuPercent, 12.5)
        XCTAssertEqual(row?.tty, "/dev/ttys004")
        XCTAssertEqual(row?.command, "/bin/zsh -il")
        XCTAssertEqual(row?.startDate, now.addingTimeInterval(-3_723))
        XCTAssertEqual(row?.isForeground, true)
    }

    func testParsesElapsedTimeFormats() {
        XCTAssertEqual(ProcessSnapshot.parseElapsedTime("05:09"), 309)
        XCTAssertEqual(ProcessSnapshot.parseElapsedTime("01:02:03"), 3_723)
        XCTAssertEqual(ProcessSnapshot.parseElapsedTime("2-01:02:03"), 176_523)
        XCTAssertNil(ProcessSnapshot.parseElapsedTime("garbage"))
    }

    func testTreatsMissingTTYAsNil() {
        let line = "  99     1    99     0 Ss     0.0 10:00 ?? /usr/libexec/somethingd"
        let row = ProcessSnapshot.parseProcessLine(line[...], now: now)
        XCTAssertNil(row?.tty)
    }

    func testForegroundRowPrefersGroupLeaderOfForegroundGroup() {
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 100, ppid: 1, pgid: 100, tpgid: 300, stat: "Ss", tty: "/dev/ttys001", command: "/bin/zsh"),
            row(pid: 300, ppid: 100, pgid: 300, tpgid: 300, stat: "S+", tty: "/dev/ttys001", command: "claude"),
            row(pid: 301, ppid: 300, pgid: 300, tpgid: 300, stat: "S+", tty: "/dev/ttys001", command: "node worker")
        ])

        XCTAssertEqual(snapshot.foregroundRow(for: "/dev/ttys001")?.pid, 300)
    }

    func testAggregateCPUSumsSubtree() {
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 10, ppid: 1, cpu: 2.0),
            row(pid: 11, ppid: 10, cpu: 30.0),
            row(pid: 12, ppid: 11, cpu: 8.0),
            row(pid: 99, ppid: 1, cpu: 50.0)
        ])

        XCTAssertEqual(snapshot.aggregateCPU(of: 10), 40.0, accuracy: 0.01)
    }

    // MARK: - Terminal identity

    func testCmuxEmbeddedGhosttyIsIdentifiedAsCmux() {
        // Cmux ships its own ghostty binary; the executable-name check for
        // Ghostty must not shadow the Cmux bundle path.
        let cmuxGhostty = row(
            pid: 5, ppid: 1,
            command: "/Applications/cmux.app/Contents/Resources/bin/ghostty --embedded"
        )
        let identity = TerminalIdentityResolver.identity(for: cmuxGhostty)
        XCTAssertEqual(identity?.name, "Cmux")
        XCTAssertEqual(identity?.bundleID, "com.cmuxterm.app")
    }

    func testRealGhosttyStillIdentified() {
        let ghostty = row(pid: 6, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        let identity = TerminalIdentityResolver.identity(for: ghostty)
        XCTAssertEqual(identity?.name, "Ghostty")
        XCTAssertEqual(identity?.bundleID, "com.mitchellh.ghostty")
    }

    func testUnknownAppFallsBackToOutermostBundleName() {
        let emacs = row(
            pid: 7, ppid: 1,
            command: "/Applications/Emacs.app/Contents/MacOS/Emacs --daemon"
        )
        let identity = TerminalIdentityResolver.identity(for: emacs)
        XCTAssertEqual(identity?.name, "Emacs")
        XCTAssertNil(identity?.bundleID)

        let helper = row(
            pid: 8, ppid: 1,
            command: "/Applications/Foo.app/Contents/Frameworks/Foo Helper (Renderer).app/Contents/MacOS/Foo Helper"
        )
        XCTAssertEqual(TerminalIdentityResolver.identity(for: helper)?.name, "Foo")
    }

    func testPlainCLIProcessHasNoTerminalIdentity() {
        let zsh = row(pid: 9, ppid: 1, command: "/bin/zsh -il")
        XCTAssertNil(TerminalIdentityResolver.identity(for: zsh))
    }

    func testAgentDesktopAppsAreAgentHosts() {
        let claudeApp = row(pid: 10, ppid: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude")
        let identity = TerminalIdentityResolver.identity(for: claudeApp)
        XCTAssertEqual(identity?.name, "Claude")
        XCTAssertEqual(identity?.isAgentHost, true)

        let ghostty = row(pid: 11, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        XCTAssertEqual(TerminalIdentityResolver.identity(for: ghostty)?.isAgentHost, false)
    }

    // MARK: - Agent-spawned infrastructure

    func testAgentSpawnedShellIsDetected() {
        // Ghostty → zsh → claude → zsh (tool shell on a new pty)
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 50, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            row(pid: 60, ppid: 50, tty: "/dev/ttys001", command: "/bin/zsh -il"),
            row(pid: 70, ppid: 60, tty: "/dev/ttys001", command: "claude"),
            row(pid: 80, ppid: 70, tty: "/dev/ttys009", command: "/bin/zsh -l")
        ])

        // The tool shell descends from the claude harness…
        XCTAssertTrue(snapshot.isAgentSpawned(snapshot.byPID[80]!))
        // …but the user's own shell and the harness itself do not.
        XCTAssertFalse(snapshot.isAgentSpawned(snapshot.byPID[60]!))
        XCTAssertFalse(snapshot.isAgentSpawned(snapshot.byPID[70]!))
    }

    func testLauncherChainIsNotAgentSpawned() {
        // Claude Desktop: Claude.app → disclaimer helper → bundled claude CLI.
        // The CLI's ancestors include a path that pattern-matches claude, but
        // that's its own launcher, not another agent.
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 30, ppid: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude"),
            row(pid: 40, ppid: 30, command: "/Applications/Claude.app/Contents/Helpers/disclaimer /Users/me/Library/Application Support/Claude/claude-code/2.1.197/claude.app/Contents/MacOS/claude"),
            row(pid: 41, ppid: 40, command: "/Users/me/Library/Application Support/Claude/claude-code/2.1.197/claude.app/Contents/MacOS/claude --resume")
        ])

        // The disclaimer launcher must not read as a harness at all…
        XCTAssertNil(HarnessDetection.harness(for: snapshot.byPID[40]!))
        // …and the real CLI is a user session, not agent-spawned.
        XCTAssertEqual(HarnessDetection.harness(for: snapshot.byPID[41]!), .claude)
        XCTAssertFalse(snapshot.isAgentSpawned(snapshot.byPID[41]!))
    }

    func testCrossHarnessSpawnIsAgentSpawned() {
        // pi directly spawning a codex tool child: different harness above →
        // the child is pi's work, not its own session.
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 60, ppid: 1, tty: "/dev/ttys001", command: "/bin/zsh -il"),
            row(pid: 70, ppid: 60, tty: "/dev/ttys001", command: "/Users/me/.local/bin/pi"),
            row(pid: 90, ppid: 70, command: "/Users/me/.local/bin/codex exec --json")
        ])
        XCTAssertTrue(snapshot.isAgentSpawned(snapshot.byPID[90]!))
    }

    func testTTYRootRowFindsLoginShell() {
        let snapshot = ProcessSnapshot(rows: [
            row(pid: 60, ppid: 50, tty: "/dev/ttys001", command: "/bin/zsh -il"),
            row(pid: 70, ppid: 60, tty: "/dev/ttys001", command: "claude"),
            row(pid: 75, ppid: 70, tty: "/dev/ttys001", command: "node worker")
        ])
        XCTAssertEqual(snapshot.ttyRootRow(for: "/dev/ttys001")?.pid, 60)
    }

    // MARK: - Helpers

    private func row(
        pid: Int,
        ppid: Int,
        pgid: Int? = nil,
        tpgid: Int = 0,
        stat: String = "S",
        cpu: Double = 0,
        tty: String? = nil,
        command: String = "/bin/zsh"
    ) -> ProcessRow {
        ProcessRow(
            pid: pid,
            ppid: ppid,
            pgid: pgid ?? pid,
            tpgid: tpgid,
            stat: stat,
            cpuPercent: cpu,
            startDate: nil,
            tty: tty,
            command: command
        )
    }
}
