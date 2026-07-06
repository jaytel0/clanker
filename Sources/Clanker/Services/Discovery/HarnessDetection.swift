import Foundation

/// Classifies a process row as a coding-agent harness.
///
/// Signals come in two strengths:
///   * **Strong** — unambiguous install paths ("@anthropic-ai/claude-code",
///     "/.opencode/bin/"). Trusted anywhere.
///   * **Weak** — bare executable names ("claude", "codex"). Only trusted for
///     plain CLI processes; GUI bundle internals are excluded because their
///     space-containing paths make name extraction unreliable and their
///     binaries collide with harness names (Claude.app's Electron helpers,
///     Codex's "Codex Computer Use.app" service, …).
enum HarnessDetection {
    /// Launcher/shim executables whose *arguments* contain harness paths but
    /// which are not the harness themselves. Claude Desktop's `disclaimer`
    /// helper launches the bundled claude binary and would otherwise match
    /// the "/claude-code/" path signal via its argv.
    private static let launcherExecutables: Set<String> = ["disclaimer"]

    static func harness(for row: ProcessRow) -> HarnessID? {
        guard !launcherExecutables.contains(row.executableName.lowercased()) else { return nil }
        if isCodexProcess(row) { return .codex }
        if isClaudeProcess(row) { return .claude }
        if isPiProcess(row) { return .pi }
        if isOpenCodeProcess(row) { return .opencode }
        if isGeminiProcess(row) { return .gemini }
        if isCursorAgentProcess(row) { return .cursor }
        return nil
    }

    static func isHarnessProcess(_ row: ProcessRow) -> Bool {
        harness(for: row) != nil
    }

    /// True when the command runs from inside an .app bundle — an Electron
    /// helper, XPC service, or app binary rather than a CLI tool.
    private static func isGUIAppInternal(_ command: String) -> Bool {
        command.contains(".app/contents/")
    }

    static func isCodexProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()
        guard !isCodexAppServerProcess(row) else { return false }

        if command.contains("@openai/codex")
            || command.contains("@openai+codex")
            || command.contains("/codex.app/contents/resources/codex") {
            return true
        }
        guard !isGUIAppInternal(command) else { return false }
        return row.executableName.lowercased() == "codex"
            || command.contains("/codex/codex")
    }

    static func isCodexAppServerProcess(_ row: ProcessRow) -> Bool {
        row.command.lowercased().contains(" app-server")
    }

    static func isClaudeProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()

        if command.contains("@anthropic-ai/claude-code")
            || command.contains("/claude-code/")
            || command.contains("/.claude/local/claude") {
            return true
        }
        guard !isGUIAppInternal(command) else { return false }
        let executable = row.executableName.lowercased()
        if executable == "claude" || executable == "claude-code" {
            return true
        }
        // Interpreter-wrapped launches ("node /path/to/claude"). Restricting
        // to known interpreters avoids `less /notes/claude todo` style false
        // positives that a bare "/claude " substring match produced.
        if ["node", "bun", "deno"].contains(executable),
           let script = command.split(separator: " ").dropFirst().first {
            return URL(fileURLWithPath: String(script)).lastPathComponent == "claude"
        }
        return false
    }

    static func isPiProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()

        if command.contains("/pi/agent/") {
            return true
        }
        guard !isGUIAppInternal(command) else { return false }
        return row.executableName.lowercased() == "pi"
            || command.hasSuffix("/bin/pi")
            || command.contains("/bin/pi ")
    }

    static func isOpenCodeProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()

        if command.contains("/.opencode/bin/") || command.contains("opencode-ai") {
            return true
        }
        guard !isGUIAppInternal(command) else { return false }
        return row.executableName.lowercased() == "opencode"
    }

    static func isGeminiProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()

        if command.contains("@google/gemini-cli") || command.contains("/gemini-cli/") {
            return true
        }
        guard !isGUIAppInternal(command) else { return false }
        return row.executableName.lowercased() == "gemini"
    }

    static func isCursorAgentProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()
        guard !isGUIAppInternal(command) else { return false }
        return row.executableName.lowercased() == "cursor-agent"
            || command.contains("/cursor-agent ")
            || command.hasSuffix("/cursor-agent")
    }
}
