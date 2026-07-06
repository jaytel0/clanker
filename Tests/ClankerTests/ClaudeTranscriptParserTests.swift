import XCTest
@testable import Clanker

final class ClaudeTranscriptParserTests: XCTestCase {
    func testPendingOrdinaryToolIsNotBlockedOnQuestion() throws {
        // Assistant fired Bash and the result hasn't landed yet — the agent
        // is working, not waiting on the user.
        let summary = try parse(lines: [
            userText("please build the app", at: "2026-07-06T10:00:00Z"),
            assistantToolUse(id: "tool-1", name: "Bash", at: "2026-07-06T10:00:05Z")
        ])

        XCTAssertFalse(summary.blockedOnQuestion)
        XCTAssertEqual(summary.pendingToolName, "Bash")
    }

    func testPendingQuestionToolBlocksOnUser() throws {
        let summary = try parse(lines: [
            userText("refactor?", at: "2026-07-06T10:00:00Z"),
            assistantToolUse(id: "tool-2", name: "AskUserQuestion", at: "2026-07-06T10:00:05Z")
        ])

        XCTAssertTrue(summary.blockedOnQuestion)
        XCTAssertNil(summary.pendingToolName)
    }

    func testResolvedToolLeavesNothingPending() throws {
        let summary = try parse(lines: [
            userText("run tests", at: "2026-07-06T10:00:00Z"),
            assistantToolUse(id: "tool-3", name: "Bash", at: "2026-07-06T10:00:05Z"),
            toolResult(id: "tool-3", at: "2026-07-06T10:00:20Z")
        ])

        XCTAssertFalse(summary.blockedOnQuestion)
        XCTAssertNil(summary.pendingToolName)
    }

    func testOlderTurnsPendingToolsAreIgnored() throws {
        // Turn 1 ended with an unresolved tool (aborted); turn 2 is a fresh
        // user message. The stale pending tool must not leak forward.
        let summary = try parse(lines: [
            userText("first task", at: "2026-07-06T09:00:00Z"),
            assistantToolUse(id: "tool-4", name: "Bash", at: "2026-07-06T09:00:05Z"),
            userText("actually, never mind — status?", at: "2026-07-06T10:00:00Z")
        ])

        XCTAssertFalse(summary.blockedOnQuestion)
        XCTAssertNil(summary.pendingToolName)
    }

    // MARK: - Fixtures

    private func parse(lines: [String]) throws -> ClaudeTranscriptSummary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ClaudeTranscriptParser.parse(file: url, fallbackSessionID: "test-session"))
    }

    private func userText(_ text: String, at timestamp: String) -> String {
        """
        {"type":"user","timestamp":"\(timestamp)","cwd":"/tmp/project","sessionId":"test-session","message":{"role":"user","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func assistantToolUse(id: String, name: String, at timestamp: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"test-session","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"\(id)","name":"\(name)","input":{}}]}}
        """
    }

    private func toolResult(id: String, at timestamp: String) -> String {
        """
        {"type":"user","timestamp":"\(timestamp)","sessionId":"test-session","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(id)","content":"done"}]}}
        """
    }
}
