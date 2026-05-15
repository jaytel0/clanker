import XCTest
@testable import Clanker

final class SessionCloseCapabilityTests: XCTestCase {
    func testOnlyProcessGroupCloseRequiresConfirmation() {
        XCTAssertFalse(SessionCloseCapability.none.canClose)
        XCTAssertTrue(SessionCloseCapability.terminalSession.canClose)
        XCTAssertTrue(SessionCloseCapability.processGroup.canClose)

        XCTAssertFalse(SessionCloseCapability.none.requiresConfirmation)
        XCTAssertFalse(SessionCloseCapability.terminalSession.requiresConfirmation)
        XCTAssertTrue(SessionCloseCapability.processGroup.requiresConfirmation)
    }

    func testTerminalAndITermRequireTTYForTerminalClose() {
        XCTAssertEqual(
            capability(isProcessSource: false, pid: nil, terminalName: "Terminal", tty: nil),
            .none
        )
        XCTAssertEqual(
            capability(isProcessSource: true, pid: 123, terminalName: "Terminal", tty: nil),
            .processGroup
        )
        XCTAssertEqual(
            capability(isProcessSource: true, pid: 123, terminalName: "Terminal", tty: "/dev/ttys001"),
            .terminalSession
        )
        XCTAssertEqual(
            capability(isProcessSource: true, pid: 123, terminalName: "iTerm2", tty: "/dev/ttys002"),
            .terminalSession
        )
    }

    func testAXBackedTerminalsCanCloseWithoutTTY() {
        for terminalName in ["Ghostty", "Warp", "WezTerm", "Kitty", "Alacritty"] {
            XCTAssertEqual(
                capability(isProcessSource: true, pid: 123, terminalName: terminalName, tty: nil),
                .terminalSession,
                terminalName
            )
        }
    }

    func testUnsupportedOrNonLiveSessionsDoNotAdvertiseTerminalClose() {
        XCTAssertEqual(
            capability(isLive: false, isProcessSource: true, pid: 123, terminalName: "Ghostty", tty: nil),
            .none
        )
        XCTAssertEqual(
            capability(isProcessSource: false, pid: 123, terminalName: "UnknownTerm", tty: "/dev/ttys001"),
            .none
        )
        XCTAssertEqual(
            capability(isProcessSource: true, pid: 123, terminalName: "UnknownTerm", tty: "/dev/ttys001"),
            .processGroup
        )
    }

    private func capability(
        isLive: Bool = true,
        isProcessSource: Bool,
        pid: Int?,
        terminalName: String?,
        tty: String?
    ) -> SessionCloseCapability {
        SessionCloseCapabilityResolver.capability(
            isLive: isLive,
            isProcessSource: isProcessSource,
            pid: pid,
            terminalName: terminalName,
            tty: tty
        )
    }
}
