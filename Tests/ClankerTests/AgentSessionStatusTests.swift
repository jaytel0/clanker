import XCTest
@testable import Clanker

final class AgentSessionStatusTests: XCTestCase {
    func testCountsAsLiveActiveExcludesOpenIdleRows() {
        XCTAssertFalse(session(status: .idle).countsAsLiveActive)
        XCTAssertFalse(session(status: .active).countsAsLiveActive)
        XCTAssertFalse(session(status: .completed).countsAsLiveActive)
        XCTAssertTrue(session(status: .working).countsAsLiveActive)
        XCTAssertTrue(session(status: .runningTool).countsAsLiveActive)
        XCTAssertTrue(session(status: .waitingForInput).countsAsLiveActive)
    }

    func testAttentionStatesAreSeparateFromWorkingStates() {
        XCTAssertFalse(session(status: .working).needsAttention)
        XCTAssertFalse(session(status: .runningTool).needsAttention)
        XCTAssertTrue(session(status: .waitingForInput).needsAttention)
        XCTAssertTrue(session(status: .waitingForApproval).needsAttention)
        XCTAssertTrue(session(status: .error).needsAttention)
    }

    private func session(status: SessionStatusKind, isLive: Bool = true) -> AgentSession {
        AgentSession(
            id: UUID().uuidString,
            title: "Codex",
            projectName: "clanker",
            cwd: "/tmp/clanker",
            harness: .codex,
            status: status,
            preview: "Preview",
            lastActivity: Date(),
            pid: 123,
            terminalName: "Ghostty",
            tty: "/dev/ttys001",
            isLive: isLive,
            appBundleID: "com.mitchellh.ghostty",
            launchURL: nil
        )
    }
}
