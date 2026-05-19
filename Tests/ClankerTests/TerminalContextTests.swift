import XCTest
@testable import Clanker

final class TerminalContextTests: XCTestCase {
    func testCWDOnlyContextDoesNotCountAsTerminalBacked() {
        let context = TerminalContext(
            terminalBundleID: nil,
            terminalProgram: nil,
            terminalSessionID: nil,
            iTermSessionID: nil,
            tty: nil,
            tmuxSession: nil,
            tmuxPane: nil,
            cwd: "/Users/example/project",
            source: .transcript,
            confidence: .unknown
        )

        XCTAssertFalse(context.hasTerminalBacking)
        XCTAssertNil(context.stableIdentityKey)
    }

    func testStableIdentityPrefersNativeTerminalThenITermThenTmux() {
        let native = context(
            terminalSessionID: "ghostty-terminal",
            iTermSessionID: "iterm-session",
            tmuxSession: "main",
            tmuxPane: "1.2"
        )
        XCTAssertEqual(native.stableIdentityKey, "terminalSession:ghostty-terminal")

        let iterm = context(iTermSessionID: "iterm-session", tmuxSession: "main", tmuxPane: "1.2")
        XCTAssertEqual(iterm.stableIdentityKey, "iTermSession:iterm-session")

        let tmux = context(tmuxSession: "main", tmuxPane: "1.2")
        XCTAssertEqual(tmux.stableIdentityKey, "tmux:main:1.2")
        XCTAssertEqual(tmux.tmuxTarget, "main:1.2")
    }

    func testMergeKeepsHigherConfidenceFieldsAndFillsMissingFallbacks() {
        let processContext = context(
            terminalBundleID: "com.mitchellh.ghostty",
            terminalProgram: "Ghostty",
            tty: "/dev/ttys001",
            source: .process,
            confidence: .medium
        )
        let tmuxContext = context(
            tmuxSession: "work",
            tmuxPane: "2.1",
            cwd: "/Users/example/project",
            source: .tmux,
            confidence: .high
        )

        let merged = processContext.merged(with: tmuxContext)

        XCTAssertEqual(merged.terminalBundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(merged.terminalProgram, "Ghostty")
        XCTAssertEqual(merged.tty, "/dev/ttys001")
        XCTAssertEqual(merged.tmuxTarget, "work:2.1")
        XCTAssertEqual(merged.cwd, "/Users/example/project")
        XCTAssertEqual(merged.source, .tmux)
        XCTAssertEqual(merged.confidence, .high)
    }

    private func context(
        terminalBundleID: String? = nil,
        terminalProgram: String? = nil,
        terminalSessionID: String? = nil,
        iTermSessionID: String? = nil,
        tty: String? = nil,
        tmuxSession: String? = nil,
        tmuxPane: String? = nil,
        cwd: String? = nil,
        source: TerminalContextSource = .unknown,
        confidence: TerminalContextConfidence = .unknown
    ) -> TerminalContext {
        TerminalContext(
            terminalBundleID: terminalBundleID,
            terminalProgram: terminalProgram,
            terminalSessionID: terminalSessionID,
            iTermSessionID: iTermSessionID,
            tty: tty,
            tmuxSession: tmuxSession,
            tmuxPane: tmuxPane,
            cwd: cwd,
            source: source,
            confidence: confidence
        )
    }
}
