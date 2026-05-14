import Combine
import Foundation

@MainActor
final class LocalSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let sessions = LocalSessionScanner.scan()
            await MainActor.run {
                self.sessions = sessions
            }
        }
    }
}

enum LocalSessionScanner {
    private struct ProcessRow {
        let pid: Int
        let ppid: Int
        let command: String

        var executableName: String {
            guard let first = command.split(separator: " ").first else { return "" }
            return URL(fileURLWithPath: String(first).trimmingCharacters(in: CharacterSet(charactersIn: "-"))).lastPathComponent
        }
    }

    private struct TerminalShell {
        let process: ProcessRow
        let terminalName: String
    }

    static func scan() -> [AgentSession] {
        let processes = processRows()
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let children = Dictionary(grouping: processes, by: \.ppid)
        let terminalShells = processes.compactMap { row -> TerminalShell? in
            guard isTerminalSessionShell(row, byPID: byPID),
                  let terminalName = terminalAncestorName(for: row, byPID: byPID) else {
                return nil
            }
            return TerminalShell(process: row, terminalName: terminalName)
        }

        var livePiProjectPaths = Set<String>()
        var sessions = terminalShells.map { terminalShell -> AgentSession in
            let shell = terminalShell.process
            let descendants = descendants(of: shell.pid, children: children)
            let harnessProcess = harnessProcess(in: descendants)

            let harness: HarnessID
            if let harnessProcess, isCodexProcess(harnessProcess) {
                harness = .codex
            } else if let harnessProcess, isClaudeProcess(harnessProcess) {
                harness = .claude
            } else if let harnessProcess, isPiProcess(harnessProcess) {
                harness = .pi
            } else {
                harness = .terminal
            }

            let cwd = cwd(for: harnessProcess?.pid ?? shell.pid) ?? cwd(for: shell.pid) ?? NSHomeDirectory()
            let project = projectName(for: cwd)
            let shellTTY = tty(for: shell.pid)
            let title: String
            let status: SessionStatusKind
            let preview: String

            switch harness {
            case .codex:
                title = "Codex"
                status = .active
                preview = "\(terminalShell.terminalName) PID \(shell.pid)"
            case .claude:
                title = "Claude Code"
                status = .active
                preview = "\(terminalShell.terminalName) PID \(shell.pid)"
            case .pi:
                title = "Pi"
                status = .active
                preview = "\(terminalShell.terminalName) PID \(shell.pid)"
                livePiProjectPaths.insert(cwd)
            case .terminal:
                title = shell.executableName
                status = .idle
                preview = "\(terminalShell.terminalName) PID \(shell.pid)"
            }

            return AgentSession(
                id: "terminal-\(shell.pid)",
                title: title,
                projectName: project,
                cwd: abbreviateHome(cwd),
                harness: harness,
                status: status,
                preview: preview,
                lastActivity: processActivityDate(for: harnessProcess?.pid ?? shell.pid),
                pid: shell.pid,
                terminalName: terminalShell.terminalName,
                tty: shellTTY
            )
        }

        sessions.append(contentsOf: recentPiSessions(excludingProjectPaths: livePiProjectPaths))
        // De-duplicate noisy nested shells (zsh under zsh under login) so each
        // controlling terminal contributes a single row.
        sessions = uniqueByTTY(sessions)
        return sessions.sortedForNotch()
    }

    private static func processRows() -> [ProcessRow] {
        run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="])
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { return nil }
                return ProcessRow(pid: pid, ppid: ppid, command: String(parts[2]))
            }
    }

    private static func terminalAncestorName(for row: ProcessRow, byPID: [Int: ProcessRow]) -> String? {
        var ppid = row.ppid
        var seen = Set<Int>()
        while ppid > 1, !seen.contains(ppid) {
            seen.insert(ppid)
            guard let parent = byPID[ppid] else { break }
            if let terminalName = terminalName(for: parent) {
                return terminalName
            }
            ppid = parent.ppid
        }
        return nil
    }

    private static func terminalName(for row: ProcessRow) -> String? {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()

        if executable == "ghostty" || command.contains("/ghostty.app/contents/macos/ghostty") {
            return "Ghostty"
        }
        if command.contains("/terminal.app/contents/macos/terminal") {
            return "Terminal"
        }
        if executable == "iterm2" || command.contains("/iterm.app/") || command.contains("/iterm2.app/") {
            return "iTerm"
        }
        if executable == "warp" || command.contains("/warp.app/") {
            return "Warp"
        }
        if executable == "wezterm-gui" || command.contains("/wezterm.app/") {
            return "WezTerm"
        }
        if executable == "kitty" || command.contains("/kitty.app/") {
            return "Kitty"
        }
        if executable == "alacritty" || command.contains("/alacritty.app/") {
            return "Alacritty"
        }

        return nil
    }

    private static func isTerminalSessionShell(_ row: ProcessRow, byPID: [Int: ProcessRow]) -> Bool {
        guard ["zsh", "bash", "fish", "nu"].contains(row.executableName),
              let parent = byPID[row.ppid] else {
            return false
        }

        return parent.executableName == "login"
            || parent.command.contains("/usr/bin/login")
            || terminalName(for: parent) != nil
    }

    private static func descendants(of pid: Int, children: [Int: [ProcessRow]]) -> [ProcessRow] {
        let direct = children[pid] ?? []
        return direct + direct.flatMap { descendants(of: $0.pid, children: children) }
    }

    private static func harnessProcess(in descendants: [ProcessRow]) -> ProcessRow? {
        descendants.first(where: isCodexProcess)
            ?? descendants.first(where: isClaudeProcess)
            ?? descendants.first(where: isPiProcess)
    }

    private static func isCodexProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()
        return executable == "codex"
            || command.contains("/codex")
            || command.contains("@openai/codex")
            || command.contains("@openai+codex")
    }

    private static func isClaudeProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()
        return executable == "claude"
            || executable == "claude-code"
            || command.contains("/claude")
            || command.contains("@anthropic-ai/claude-code")
    }

    private static func isPiProcess(_ row: ProcessRow) -> Bool {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()
        return executable == "pi"
            || command.hasSuffix("/bin/pi")
            || command.contains("/bin/pi ")
    }

    private static func cwd(for pid: Int) -> String? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.first == "n" else { return nil }
                return String(line.dropFirst())
            }
            .first
    }

    /// Returns the controlling tty for a pid as a normalized device path, e.g.
    /// `/dev/ttys004`. Returns nil for daemons without a controlling terminal.
    private static func tty(for pid: Int) -> String? {
        let raw = run("/bin/ps", ["-p", String(pid), "-o", "tty="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "??", raw != "-" else { return nil }
        if raw.hasPrefix("/dev/") { return raw }
        if raw.hasPrefix("tty") { return "/dev/\(raw)" }
        return "/dev/tty\(raw)"
    }

    private static func uniqueByTTY(_ sessions: [AgentSession]) -> [AgentSession] {
        var seen = Set<String>()
        var result: [AgentSession] = []
        for session in sessions {
            if let tty = session.tty {
                if seen.contains(tty) { continue }
                seen.insert(tty)
            }
            result.append(session)
        }
        return result
    }

    private static func processActivityDate(for pid: Int) -> Date {
        let output = run("/bin/ps", ["-p", String(pid), "-o", "lstart="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: output) ?? Date()
    }

    private static func recentPiSessions(excludingProjectPaths livePiProjectPaths: Set<String>) -> [AgentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-30 * 60)
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= cutoff else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .compactMap { url, modified in
                let cwd = parsePiCWD(from: url) ?? decodePiProjectPath(url.deletingLastPathComponent().lastPathComponent)
                guard !livePiProjectPaths.contains(cwd) else { return nil }
                let project = projectName(for: cwd)
                return AgentSession(
                    id: "pi-\(url.lastPathComponent)",
                    title: "Pi session",
                    projectName: project,
                    cwd: abbreviateHome(cwd),
                    harness: .pi,
                    status: Date().timeIntervalSince(modified) < 10 * 60 ? .active : .completed,
                    preview: url.lastPathComponent,
                    lastActivity: modified,
                    pid: nil,
                    terminalName: nil
                )
            }
    }

    private static func parsePiCWD(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "session",
                  let cwd = json["cwd"] as? String,
                  !cwd.isEmpty else {
                continue
            }
            return cwd
        }
        return nil
    }

    private static func decodePiProjectPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }

    private static func projectName(for cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func abbreviateHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
