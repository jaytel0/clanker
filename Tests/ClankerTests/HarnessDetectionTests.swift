import XCTest
@testable import Clanker

final class HarnessDetectionTests: XCTestCase {
    func testDetectsCodexVariants() {
        XCTAssertEqual(harness(command: "/Users/me/.local/bin/codex"), .codex)
        XCTAssertEqual(harness(command: "node /opt/lib/node_modules/@openai/codex/bin/codex.js"), .codex)
        XCTAssertEqual(harness(command: "/Applications/Codex.app/Contents/Resources/codex exec"), .codex)
    }

    func testCodexAppServerIsNotAHarness() {
        XCTAssertNil(harness(command: "/Users/me/.local/bin/codex app-server --listen ws://127.0.0.1:41241"))
    }

    func testDetectsClaudeVariants() {
        XCTAssertEqual(harness(command: "claude"), .claude)
        XCTAssertEqual(harness(command: "node /Users/me/.nvm/node_modules/@anthropic-ai/claude-code/cli.js"), .claude)
        XCTAssertEqual(harness(command: "/Users/me/.claude/local/claude --resume"), .claude)
        XCTAssertEqual(harness(command: "node /Users/me/.local/bin/claude --continue"), .claude)
    }

    func testViewingAFileNamedClaudeIsNotAHarness() {
        XCTAssertNil(harness(command: "less /docs/claude notes"))
        XCTAssertNil(harness(command: "vim /tmp/claude "))
    }

    func testDetectsPi() {
        XCTAssertEqual(harness(command: "/Users/me/.local/state/tec/toolchain/base_profile/bin/pi"), .pi)
    }

    func testDetectsOpenCode() {
        XCTAssertEqual(harness(command: "/Users/me/.opencode/bin/opencode"), .opencode)
        XCTAssertEqual(harness(command: "opencode run"), .opencode)
    }

    func testDetectsGeminiCLI() {
        XCTAssertEqual(harness(command: "node /usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"), .gemini)
        XCTAssertEqual(harness(command: "gemini"), .gemini)
    }

    func testDetectsCursorAgent() {
        XCTAssertEqual(harness(command: "/Users/me/.local/bin/cursor-agent"), .cursor)
        XCTAssertEqual(harness(command: "/Users/me/.local/bin/cursor-agent chat"), .cursor)
    }

    func testShellIsNotAHarness() {
        XCTAssertNil(harness(command: "/bin/zsh -il"))
        XCTAssertNil(harness(command: "vim notes-about-claude.md"))
    }

    func testGUIAppInternalsAreNotHarnesses() {
        // Claude Desktop and its Electron helpers must not read as Claude
        // Code sessions.
        XCTAssertNil(harness(command: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertNil(harness(command: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=utility"))
        // Codex's computer-use service tokenizes to executable "Codex".
        XCTAssertNil(harness(command: "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"))
        XCTAssertNil(harness(command: "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"))
    }

    func testBundledCodexBinaryStillDetected() {
        XCTAssertEqual(harness(command: "/Applications/Codex.app/Contents/Resources/codex exec --json"), .codex)
    }

    func testStrongClaudeSignalWinsInsideEditorBundles() {
        // VS Code's Electron node running the claude-code package is a real
        // harness even though the path is inside an .app bundle.
        XCTAssertEqual(
            harness(command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper /Users/me/.vscode/extensions/node_modules/@anthropic-ai/claude-code/cli.js"),
            .claude
        )
    }

    private func harness(command: String) -> HarnessID? {
        HarnessDetection.harness(for: ProcessRow(
            pid: 1000,
            ppid: 999,
            pgid: 1000,
            tpgid: 1000,
            stat: "S+",
            cpuPercent: 0,
            startDate: nil,
            tty: "/dev/ttys000",
            command: command
        ))
    }
}
