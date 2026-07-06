import XCTest
@testable import Clanker

final class AttentionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNotifiesOnlyAfterDebounce() {
        var tracker = AttentionTracker(debounce: 2.5, renotifyCooldown: 60)
        let blocked = session(id: "s1", status: .waitingForApproval)

        XCTAssertEqual(tracker.update(sessions: [blocked], now: t0), [])
        XCTAssertEqual(tracker.update(sessions: [blocked], now: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(
            tracker.update(sessions: [blocked], now: t0.addingTimeInterval(3)),
            [.notify(session: blocked)]
        )
        // Already notified for this episode — no repeat.
        XCTAssertEqual(tracker.update(sessions: [blocked], now: t0.addingTimeInterval(10)), [])
    }

    func testFlappingStatusNeverNotifies() {
        var tracker = AttentionTracker(debounce: 2.5, renotifyCooldown: 60)
        let blocked = session(id: "s1", status: .waitingForApproval)
        let working = session(id: "s1", status: .working)

        var now = t0
        for tick in 0..<10 {
            let sessions = tick.isMultiple(of: 2) ? [blocked] : [working]
            let events = tracker.update(sessions: sessions, now: now)
            XCTAssertFalse(events.contains { if case .notify = $0 { true } else { false } })
            now = now.addingTimeInterval(1)
        }
    }

    func testClearsWhenSessionUnblocksOrDisappears() {
        var tracker = AttentionTracker(debounce: 0, renotifyCooldown: 60)
        let blocked = session(id: "s1", status: .waitingForInput)

        XCTAssertEqual(tracker.update(sessions: [blocked], now: t0), [])
        XCTAssertEqual(
            tracker.update(sessions: [blocked], now: t0.addingTimeInterval(0.1)),
            [.notify(session: blocked)]
        )

        let unblocked = session(id: "s1", status: .working)
        XCTAssertEqual(
            tracker.update(sessions: [unblocked], now: t0.addingTimeInterval(5)),
            [.clear(sessionID: "s1")]
        )

        // Re-enter attention, then vanish entirely.
        _ = tracker.update(sessions: [blocked], now: t0.addingTimeInterval(10))
        XCTAssertEqual(
            tracker.update(sessions: [], now: t0.addingTimeInterval(15)),
            [.clear(sessionID: "s1")]
        )
    }

    func testRenotifyRespectsCooldown() {
        var tracker = AttentionTracker(debounce: 0, renotifyCooldown: 60)
        let blocked = session(id: "s1", status: .waitingForInput)
        let working = session(id: "s1", status: .working)

        _ = tracker.update(sessions: [blocked], now: t0)
        XCTAssertEqual(
            tracker.update(sessions: [blocked], now: t0.addingTimeInterval(0.1)),
            [.notify(session: blocked)]
        )

        // Unblock and re-block 10s later: episode is new but cooldown holds.
        _ = tracker.update(sessions: [working], now: t0.addingTimeInterval(5))
        _ = tracker.update(sessions: [blocked], now: t0.addingTimeInterval(10))
        XCTAssertEqual(tracker.update(sessions: [blocked], now: t0.addingTimeInterval(11)), [])

        // After the cooldown window it may speak again.
        XCTAssertEqual(
            tracker.update(sessions: [blocked], now: t0.addingTimeInterval(70)),
            [.notify(session: blocked)]
        )
    }

    func testNonLiveSessionsAreIgnored() {
        var tracker = AttentionTracker(debounce: 0, renotifyCooldown: 60)
        let historical = session(id: "old", status: .waitingForInput, isLive: false)
        XCTAssertEqual(tracker.update(sessions: [historical], now: t0), [])
        XCTAssertEqual(tracker.update(sessions: [historical], now: t0.addingTimeInterval(5)), [])
    }

    // MARK: - Helpers

    private func session(
        id: String,
        status: SessionStatusKind,
        isLive: Bool = true
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: "Test Session",
            projectName: "proj",
            cwd: "~/proj",
            harness: .claude,
            status: status,
            preview: "preview",
            lastActivity: t0,
            pid: 123,
            terminalName: "Ghostty",
            tty: "/dev/ttys009",
            isLive: isLive,
            appBundleID: "com.mitchellh.ghostty",
            launchURL: nil
        )
    }
}

@MainActor
final class SessionReplyRouteTests: XCTestCase {
    func testTmuxTargetWinsOverEverything() {
        var context = TerminalContext.empty
        context.tmuxSession = "main"
        context.tmuxPane = "1.2"
        context.terminalBundleID = CmuxSupport.bundleID
        context.terminalSessionID = "PANEL"

        XCTAssertEqual(
            SessionReplyService.route(for: session(context: context)),
            .tmux(target: "main:1.2")
        )
    }

    func testCmuxPanelRoute() {
        var context = TerminalContext.empty
        context.terminalBundleID = CmuxSupport.bundleID
        context.terminalSessionID = "PANEL-123"

        XCTAssertEqual(
            SessionReplyService.route(for: session(context: context)),
            .cmuxPanel(id: "PANEL-123")
        )
    }

    func testITermRouteUsesTTY() {
        var context = TerminalContext.empty
        context.terminalBundleID = "com.googlecode.iterm2"
        context.tty = "/dev/ttys003"

        XCTAssertEqual(
            SessionReplyService.route(for: session(context: context)),
            .iterm(tty: "/dev/ttys003")
        )
    }

    func testKnownTerminalFallsBackToKeystrokes() {
        var context = TerminalContext.empty
        context.terminalBundleID = "com.mitchellh.ghostty"
        context.tty = "/dev/ttys004"

        XCTAssertEqual(
            SessionReplyService.route(for: session(context: context)),
            .keystrokes(bundleID: "com.mitchellh.ghostty")
        )
    }

    func testNoBackingMeansNoRoute() {
        XCTAssertEqual(
            SessionReplyService.route(for: session(context: .empty)),
            .none
        )
    }

    private func session(context: TerminalContext) -> AgentSession {
        AgentSession(
            id: "s",
            title: "t",
            projectName: "p",
            cwd: "~/p",
            harness: .claude,
            status: .waitingForInput,
            preview: "",
            lastActivity: Date(),
            pid: 1,
            terminalName: nil,
            tty: context.tty,
            isLive: true,
            appBundleID: nil,
            launchURL: nil,
            terminalContext: context
        )
    }
}
