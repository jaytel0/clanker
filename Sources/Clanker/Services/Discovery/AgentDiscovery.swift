import AppKit
import Foundation

enum LocalSessionScanner {
    private static let transcriptRefreshInterval: TimeInterval = 8

    static func scan() async -> [AgentSession] {
        let processSnapshot = ProcessSnapshot.capture()
        var discovered: [DiscoveredSession] = []

        discovered += TerminalProcessSource(snapshot: processSnapshot).scan()
        discovered += ClaudeSessionSource(snapshot: processSnapshot).scanLive()
        discovered += await TranscriptSessionCache.shared.sessions(
            snapshot: processSnapshot,
            refreshInterval: transcriptRefreshInterval
        )
        discovered += await CodexAppServerSource.shared.scan()
        discovered += await MainActor.run { MacAppSource.scan() }

        return SessionTitleHeuristics.apply(to: SessionMerger.merge(discovered))
    }
}

private actor TranscriptSessionCache {
    static let shared = TranscriptSessionCache()

    private var cached: [DiscoveredSession] = []
    private var refreshedAt: Date = .distantPast

    func sessions(snapshot: ProcessSnapshot, refreshInterval: TimeInterval) -> [DiscoveredSession] {
        let now = Date()
        guard cached.isEmpty || now.timeIntervalSince(refreshedAt) >= refreshInterval else {
            return cached
        }

        cached = CodexTranscriptSource(snapshot: snapshot).scan()
            + ClaudeSessionSource(snapshot: snapshot).scanHistorical()
            + PiSessionSource(snapshot: snapshot).scan()
        refreshedAt = now
        return cached
    }
}

// MARK: - Normalized Discovery Model

private enum DiscoverySourceKind: Int, Sendable {
    case appServer = 90
    case transcript = 70
    case process = 50
    case app = 30
}

private struct DiscoveredSession: Sendable {
    var sessionKey: String?
    var sourceKind: DiscoverySourceKind
    var id: String
    var title: String
    var cwd: String
    var harness: HarnessID
    var status: SessionStatusKind
    var preview: String
    var lastActivity: Date
    var pid: Int?
    var terminalName: String?
    var tty: String?
    var appBundleID: String?
    var launchURL: String?

    var normalizedCWD: String {
        DiscoveryHelpers.normalizedPath(cwd)
    }

    var isTerminalBacked: Bool {
        terminalName?.isEmpty == false || tty?.isEmpty == false
    }

    var isLive: Bool {
        switch sourceKind {
        case .process, .appServer, .app:
            return true
        case .transcript:
            return pid != nil || tty != nil || terminalName?.isEmpty == false
        }
    }

    var closeCapability: SessionCloseCapability {
        SessionCloseCapabilityResolver.capability(
            isLive: isLive,
            isProcessSource: sourceKind == .process,
            pid: pid,
            terminalName: terminalName,
            tty: tty
        )
    }

    func asAgentSession() -> AgentSession {
        AgentSession(
            id: id,
            title: title,
            projectName: DiscoveryHelpers.projectName(for: cwd),
            cwd: DiscoveryHelpers.abbreviateHome(cwd),
            harness: harness,
            status: status,
            preview: preview,
            lastActivity: lastActivity,
            pid: pid,
            terminalName: terminalName,
            tty: tty,
            isLive: isLive,
            appBundleID: appBundleID,
            launchURL: launchURL,
            closeCapability: closeCapability
        )
    }
}

private enum SessionMerger {
    static func merge(_ candidates: [DiscoveredSession]) -> [AgentSession] {
        var merged: [DiscoveredSession] = []

        for candidate in candidates.sorted(by: shouldVisitBefore) {
            if let index = exactMatchIndex(for: candidate, in: merged) {
                merged[index] = combine(merged[index], candidate)
                continue
            }

            if let index = contextualMatchIndex(for: candidate, in: merged) {
                merged[index] = combine(merged[index], candidate)
                continue
            }

            merged.append(candidate)
        }

        return merged
            .map { $0.asAgentSession() }
            .sortedForNotch()
    }

    private static func shouldVisitBefore(_ lhs: DiscoveredSession, _ rhs: DiscoveredSession) -> Bool {
        if lhs.sourceKind.rawValue != rhs.sourceKind.rawValue {
            return lhs.sourceKind.rawValue > rhs.sourceKind.rawValue
        }
        return lhs.lastActivity > rhs.lastActivity
    }

    private static func exactMatchIndex(for candidate: DiscoveredSession, in sessions: [DiscoveredSession]) -> Int? {
        if let key = candidate.sessionKey {
            if let index = sessions.firstIndex(where: { $0.sessionKey == key }) {
                return index
            }
        }

        if let tty = candidate.tty {
            if let index = sessions.firstIndex(where: {
                $0.harness == candidate.harness && $0.tty == tty
            }) {
                return index
            }
        }

        if let pid = candidate.pid {
            return sessions.firstIndex {
                $0.harness == candidate.harness && $0.pid == pid
            }
        }

        return nil
    }

    private static func contextualMatchIndex(for candidate: DiscoveredSession, in sessions: [DiscoveredSession]) -> Int? {
        guard candidate.harness != .terminal else { return nil }

        let matches = sessions.indices.filter { index in
            let existing = sessions[index]
            guard existing.harness == candidate.harness else { return false }
            guard existing.normalizedCWD == candidate.normalizedCWD else { return false }
            guard existing.isTerminalBacked != candidate.isTerminalBacked else { return false }
            return abs(existing.lastActivity.timeIntervalSince(candidate.lastActivity)) < 12 * 60 * 60
        }

        // When multiple candidates overlap on (harness, cwd) — e.g. several
        // transcripts in the same Pi project dir from prior sessions — the
        // old behaviour bailed entirely, leaving the live terminal session
        // with its stale process-start `lastActivity`. That broke the
        // "Working\u{2026}" pill, which keys off transcript-mtime freshness.
        //
        // Pick the match with the most recent activity instead. For a live
        // process row that means absorbing the freshest transcript — which
        // is the one the user is currently writing into. Stale transcripts
        // remain in the merged set but are filtered out at the ViewModel
        // (transcript-only rows fail `isLive`), so no UI duplication.
        return matches.max { sessions[$0].lastActivity < sessions[$1].lastActivity }
    }

    private static func combine(_ lhs: DiscoveredSession, _ rhs: DiscoveredSession) -> DiscoveredSession {
        let preferred = lhs.sourceKind.rawValue >= rhs.sourceKind.rawValue ? lhs : rhs
        let other = lhs.sourceKind.rawValue >= rhs.sourceKind.rawValue ? rhs : lhs
        let status = mostImportantStatus(lhs.status, rhs.status)
        let lastActivity = max(lhs.lastActivity, rhs.lastActivity)

        return DiscoveredSession(
            sessionKey: preferred.sessionKey ?? other.sessionKey,
            sourceKind: preferred.sourceKind,
            id: preferred.sessionKey ?? preferred.id,
            title: richerTitle(preferred.title, fallback: other.title, harness: preferred.harness),
            cwd: DiscoveryHelpers.isUsefulPath(preferred.cwd) ? preferred.cwd : other.cwd,
            harness: preferred.harness,
            status: status,
            preview: richerPreview(preferred.preview, fallback: other.preview),
            lastActivity: lastActivity,
            pid: preferred.pid ?? other.pid,
            terminalName: preferred.terminalName ?? other.terminalName,
            tty: preferred.tty ?? other.tty,
            appBundleID: hostAppBundleID(preferred, other),
            launchURL: preferred.launchURL ?? other.launchURL
        )
    }

    private static func hostAppBundleID(_ lhs: DiscoveredSession, _ rhs: DiscoveredSession) -> String? {
        if lhs.isTerminalBacked, let bundleID = lhs.appBundleID {
            return bundleID
        }
        if rhs.isTerminalBacked, let bundleID = rhs.appBundleID {
            return bundleID
        }
        return lhs.appBundleID ?? rhs.appBundleID
    }

    private static func mostImportantStatus(_ lhs: SessionStatusKind, _ rhs: SessionStatusKind) -> SessionStatusKind {
        func rank(_ status: SessionStatusKind) -> Int {
            switch status {
            case .waitingForApproval: 80
            case .waitingForInput: 70
            case .error: 60
            case .working: 55
            case .runningTool: 50
            case .thinking: 45
            case .active: 40
            case .idle: 20
            case .completed: 10
            }
        }

        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func richerTitle(_ title: String, fallback: String, harness: HarnessID) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard !fallback.isEmpty else { return trimmed }

        switch harness {
        case .terminal:
            return trimmed
        case .codex where trimmed == "Codex" && fallback != "Codex":
            return fallback
        case .claude where trimmed == "Claude Code" && fallback != "Claude Code":
            return fallback
        case .pi where trimmed == "Pi" && fallback != "Pi":
            return fallback
        default:
            return trimmed
        }
    }

    private static func richerPreview(_ preview: String, fallback: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("PID ") {
            return trimmed
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? trimmed
    }
}

// MARK: - Process Snapshot

private struct TerminalIdentity: Sendable, Hashable {
    var name: String
    var bundleID: String?
}

private struct ProcessRow: Sendable, Hashable {
    let pid: Int
    let ppid: Int
    let tty: String?
    let command: String

    var executableName: String {
        guard let first = command.split(separator: " ").first else { return "" }
        let token = String(first)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return URL(fileURLWithPath: token).lastPathComponent
    }
}

private struct ProcessSnapshot: Sendable {
    let rows: [ProcessRow]
    let byPID: [Int: ProcessRow]
    let children: [Int: [ProcessRow]]
    let rowsByTTY: [String: [ProcessRow]]

    static func capture() -> ProcessSnapshot {
        let rows = ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="])
            .split(separator: "\n")
            .compactMap(ProcessSnapshot.parseProcessLine)
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        let children = Dictionary(grouping: rows, by: \.ppid)
        let rowsByTTY = Dictionary(grouping: rows.compactMap { row -> (String, ProcessRow)? in
            guard let tty = row.tty else { return nil }
            return (tty, row)
        }, by: \.0).mapValues { $0.map(\.1) }

        return ProcessSnapshot(rows: rows, byPID: byPID, children: children, rowsByTTY: rowsByTTY)
    }

    func descendants(of pid: Int) -> [ProcessRow] {
        let direct = children[pid] ?? []
        return direct + direct.flatMap { descendants(of: $0.pid) }
    }

    func terminalContext(for row: ProcessRow) -> TerminalIdentity? {
        if let direct = TerminalProcessSource.terminalIdentity(for: row) {
            return direct
        }

        var current = row.ppid
        var depth = 0
        var seen = Set<Int>()
        while current > 1, depth < 40, !seen.contains(current) {
            seen.insert(current)
            guard let parent = byPID[current] else { break }
            if let terminal = TerminalProcessSource.terminalIdentity(for: parent) {
                return terminal
            }
            current = parent.ppid
            depth += 1
        }

        return nil
    }

    func isDescendant(_ pid: Int, of ancestor: Int) -> Bool {
        var current = pid
        var depth = 0
        while current > 1, depth < 60 {
            if current == ancestor { return true }
            guard let row = byPID[current] else { break }
            current = row.ppid
            depth += 1
        }
        return false
    }

    private static func parseProcessLine(_ line: Substring) -> ProcessRow? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else {
            return nil
        }

        return ProcessRow(
            pid: pid,
            ppid: ppid,
            tty: DiscoveryHelpers.normalizedTTY(String(parts[2])),
            command: String(parts[3])
        )
    }
}

// MARK: - Terminal and Process Source

private struct TerminalProcessSource {
    let snapshot: ProcessSnapshot

    /// Pick the harness rooted closest to the user's prompt for this tty.
    ///
    /// Strategy: starting at the foreground process, walk the parent chain
    /// upward; the first harness process we encounter on that walk is the
    /// one the user typed. If the foreground process itself isn't yet known
    /// (race or missing pid), fall back to the *lowest-PID* harness in the
    /// tty's row set — first harness spawned tends to be the user's, with
    /// any nested harnesses (codex app-server, etc.) coming later.
    fileprivate func harnessRowFromForeground(
        foregroundPid: Int?,
        tty: String,
        rows: [ProcessRow]
    ) -> ProcessRow? {
        if let foregroundPid {
            var pid = foregroundPid
            var depth = 0
            while depth < 40, let row = snapshot.byPID[pid] {
                if isHarnessProcess(row) { return row }
                if pid == row.ppid { break }
                pid = row.ppid
                depth += 1
            }
        }
        // Lowest-PID harness in the tty's set is a much better default than
        // highest — child harnesses (Codex app-server spawned by Pi, vendor
        // codex spawned by the node codex wrapper) always have larger PIDs.
        return rows.sorted { $0.pid < $1.pid }.first(where: isHarnessProcess)
    }

    func scan() -> [DiscoveredSession] {
        var sessions: [DiscoveredSession] = []
        var coveredPIDs = Set<Int>()

        for (tty, rows) in snapshot.rowsByTTY {
            guard let session = sessionForTTY(tty, rows: rows) else { continue }
            if let pid = session.pid {
                coveredPIDs.insert(pid)
            }
            sessions.append(session)
        }

        sessions += orphanHarnessSessions(excluding: coveredPIDs)
        return sessions
    }

    private func sessionForTTY(_ tty: String, rows: [ProcessRow]) -> DiscoveredSession? {
        let terminal = rows.compactMap { snapshot.terminalContext(for: $0) }.first
        let shellRow = bestShell(in: rows)

        // Pick the harness the *user actually invoked* in this tab. The
        // foreground process is the right anchor: ground truth for "what's
        // running in this terminal". We walk the parent chain from there
        // upward and grab the first harness we hit.
        //
        // Why not "highest PID matching isHarnessProcess"? Because tools
        // routinely spawn other harnesses as children:
        //   * `pi` spawns `codex app-server` for tool calls — highest PID
        //     would pick the child (Codex), but the user invoked Pi.
        //   * `codex` (node wrapper) spawns an inner codex vendor binary
        //     whose cwd is the plugin cache, not the user's project —
        //     highest PID would pick that child too, giving a junk cwd.
        let foregroundPid = ProcessRunner.foregroundPID(for: tty)
        let harnessRow = harnessRowFromForeground(
            foregroundPid: foregroundPid,
            tty: tty,
            rows: rows
        )
        let owner = harnessRow ?? shellRow ?? rows.sorted { $0.pid > $1.pid }.first

        guard terminal != nil || harnessRow != nil else { return nil }
        guard let owner else { return nil }
        guard shellRow != nil || harnessRow != nil else { return nil }

        let harness = harnessRow.flatMap(harness(for:)) ?? .terminal
        // Prefer cwd of the foreground process — that's the user-facing
        // "where am I" answer. Fall back to the harness we picked, then
        // shell, then home.
        let cwd = (foregroundPid.flatMap { ProcessRunner.cwd(for: $0) })
            ?? ProcessRunner.cwd(for: harnessRow?.pid ?? owner.pid)
            ?? ProcessRunner.cwd(for: owner.pid)
            ?? NSHomeDirectory()
        let title: String
        let preview: String
        let status: SessionStatusKind

        switch harness {
        case .codex:
            title = "Codex"
            preview = terminal.map { "\($0.name) PID \(owner.pid)" } ?? "PID \(owner.pid)"
            status = .active
        case .claude:
            title = "Claude Code"
            preview = terminal.map { "\($0.name) PID \(owner.pid)" } ?? "PID \(owner.pid)"
            status = .active
        case .pi:
            title = "Pi"
            preview = terminal.map { "\($0.name) PID \(owner.pid)" } ?? "PID \(owner.pid)"
            status = .active
        case .terminal:
            title = owner.executableName.nonEmpty ?? "Terminal"
            preview = terminal.map { "\($0.name) PID \(owner.pid)" } ?? "PID \(owner.pid)"
            status = .idle
        }

        return DiscoveredSession(
            sessionKey: "\(harness.rawValue):tty:\(tty)",
            sourceKind: .process,
            id: "\(harness.rawValue)-tty-\(DiscoveryHelpers.identifierSafe(tty))",
            title: title,
            cwd: cwd,
            harness: harness,
            status: status,
            preview: preview,
            lastActivity: ProcessRunner.startDate(for: harnessRow?.pid ?? owner.pid) ?? Date(),
            pid: harnessRow?.pid ?? owner.pid,
            terminalName: terminal?.name,
            tty: tty,
            appBundleID: terminal?.bundleID,
            launchURL: nil
        )
    }

    private func orphanHarnessSessions(excluding coveredPIDs: Set<Int>) -> [DiscoveredSession] {
        snapshot.rows.compactMap { row -> DiscoveredSession? in
            guard !coveredPIDs.contains(row.pid),
                  row.tty == nil,
                  let harness = harness(for: row),
                  !isCodexAppServerProcess(row) else {
                return nil
            }

            let cwd = ProcessRunner.cwd(for: row.pid) ?? NSHomeDirectory()
            let title: String
            switch harness {
            case .codex: title = "Codex"
            case .claude: title = "Claude Code"
            case .pi: title = "Pi"
            case .terminal: title = row.executableName.nonEmpty ?? "Terminal"
            }

            // A no-tty Codex process whose ancestor chain includes Codex.app
            // is running inside the Mac app, not a terminal. Route it there.
            let codexMacAppInfo: (bundleID: String?, launchURL: String?)
            if harness == .codex, snapshot.isInsideCodexMacApp(pid: row.pid) {
                // Best-effort: find the most recent "exec" transcript whose
                // cwd matches this process so we can deep-link to the thread.
                let threadID = CodexTranscriptIndex.shared.threadID(forCWD: cwd)
                codexMacAppInfo = (
                    bundleID: "com.openai.codex",
                    launchURL: threadID.map { "codex://threads/\($0)" }
                )
            } else {
                codexMacAppInfo = (nil, nil)
            }

            return DiscoveredSession(
                sessionKey: "\(harness.rawValue):pid:\(row.pid)",
                sourceKind: .process,
                id: "\(harness.rawValue)-pid-\(row.pid)",
                title: title,
                cwd: cwd,
                harness: harness,
                status: .active,
                preview: "PID \(row.pid)",
                lastActivity: ProcessRunner.startDate(for: row.pid) ?? Date(),
                pid: row.pid,
                terminalName: nil,
                tty: nil,
                appBundleID: codexMacAppInfo.bundleID,
                launchURL: codexMacAppInfo.launchURL
            )
        }
    }

    private func bestShell(in rows: [ProcessRow]) -> ProcessRow? {
        rows
            .filter { Self.isInteractiveShell($0) }
            .sorted { lhs, rhs in
                if lhs.ppid != rhs.ppid {
                    return lhs.ppid > rhs.ppid
                }
                return lhs.pid > rhs.pid
            }
            .first
    }

    static func terminalIdentity(for row: ProcessRow) -> TerminalIdentity? {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()

        if executable == "terminal" || command.contains("/terminal.app/contents/macos/terminal") {
            return TerminalIdentity(name: "Terminal", bundleID: "com.apple.Terminal")
        }
        if executable == "iterm2" || executable == "iterm" || command.contains("/iterm.app/") || command.contains("/iterm2.app/") {
            return TerminalIdentity(name: "iTerm", bundleID: "com.googlecode.iterm2")
        }
        if executable == "ghostty" || command.contains("/ghostty.app/") {
            return TerminalIdentity(name: "Ghostty", bundleID: "com.mitchellh.ghostty")
        }
        if executable == "warp" || command.contains("/warp.app/") {
            return TerminalIdentity(name: "Warp", bundleID: "dev.warp.Warp-Stable")
        }
        if executable == "wezterm-gui" || executable == "wezterm" || command.contains("/wezterm.app/") {
            return TerminalIdentity(name: "WezTerm", bundleID: "com.github.wez.wezterm")
        }
        if executable == "kitty" || command.contains("/kitty.app/") {
            return TerminalIdentity(name: "Kitty", bundleID: "net.kovidgoyal.kitty")
        }
        if executable == "alacritty" || command.contains("/alacritty.app/") {
            return TerminalIdentity(name: "Alacritty", bundleID: "org.alacritty")
        }
        if command.contains("/visual studio code.app/") {
            return TerminalIdentity(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        }
        if command.contains("/cursor.app/") {
            return TerminalIdentity(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        }
        if command.contains("/windsurf.app/") {
            return TerminalIdentity(name: "Windsurf", bundleID: "com.exafunction.windsurf")
        }

        return nil
    }

    private static func isInteractiveShell(_ row: ProcessRow) -> Bool {
        let executable = row.executableName.lowercased()
        return ["zsh", "bash", "fish", "nu", "sh", "ksh", "tcsh", "csh", "pwsh", "xonsh", "elvish"].contains(executable)
    }
}

// MARK: - Codex Transcripts

private struct CodexTranscriptSource {
    let snapshot: ProcessSnapshot

    func scan() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        return DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 24 * 60 * 60, limit: 80)
            .compactMap(parseCodexTranscript)
    }

    private func parseCodexTranscript(_ file: URL, modified: Date) -> DiscoveredSession? {
        guard file.lastPathComponent.hasPrefix("rollout-"),
              let content = DiscoveryHelpers.readUTF8File(file, maxBytes: 12 * 1024 * 1024) else {
            return nil
        }

        var threadID = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "rollout-", with: "")
        var cwd = NSHomeDirectory()
        var title: String?
        var firstUserMessage: String?
        var latestUserMessage: String?
        var latestAssistantMessage: String?
        var pendingTools: [String: String] = [:]
        var waitingForInput = false
        var activeTurn = false
        var source = "cli"
        var latestTimestamp = modified

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = DiscoveryHelpers.jsonObject(fromLine: line) else { continue }
            let timestamp = DiscoveryHelpers.parseDate(json["timestamp"]) ?? modified
            latestTimestamp = max(latestTimestamp, timestamp)

            switch json["type"] as? String {
            case "session_meta":
                let payload = json["payload"] as? [String: Any] ?? [:]
                threadID = DiscoveryHelpers.string(payload["id"]) ?? threadID
                cwd = DiscoveryHelpers.string(payload["cwd"]) ?? cwd
                title = DiscoveryHelpers.string(payload["title"]) ?? title
                if let sourceValue = DiscoveryHelpers.string(payload["source"]) {
                    source = sourceValue
                } else if payload["source"] is [String: Any] {
                    source = "subagent"
                }

            case "turn_context":
                let payload = json["payload"] as? [String: Any] ?? [:]
                cwd = DiscoveryHelpers.string(payload["cwd"]) ?? cwd

            case "event_msg":
                let payload = json["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "user_message":
                    let text = DiscoveryHelpers.compactText(payload["message"])
                    firstUserMessage = firstUserMessage ?? text
                    latestUserMessage = text ?? latestUserMessage
                    activeTurn = true
                case "agent_message":
                    latestAssistantMessage = DiscoveryHelpers.compactText(payload["message"]) ?? latestAssistantMessage
                case "task_started":
                    activeTurn = true
                case "task_complete", "turn_aborted", "turn_interrupted", "task_interrupted":
                    activeTurn = false
                    pendingTools.removeAll()
                default:
                    break
                }

            case "response_item":
                let payload = json["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "function_call", "custom_tool_call", "web_search_call":
                    guard let callID = DiscoveryHelpers.string(payload["call_id"]) ?? DiscoveryHelpers.string(payload["id"]) else {
                        continue
                    }
                    let name = DiscoveryHelpers.string(payload["name"]) ?? DiscoveryHelpers.string(payload["tool"]) ?? "tool"
                    if DiscoveryHelpers.string(payload["status"]) != "completed" {
                        pendingTools[callID] = name
                    }
                    if DiscoveryHelpers.normalizedToolName(name) == "requestuserinput" {
                        waitingForInput = true
                    }
                case "function_call_output", "custom_tool_call_output":
                    if let callID = DiscoveryHelpers.string(payload["call_id"]) ?? DiscoveryHelpers.string(payload["id"]) {
                        pendingTools.removeValue(forKey: callID)
                    }
                default:
                    break
                }

            default:
                break
            }
        }

        let status: SessionStatusKind
        if waitingForInput {
            status = .waitingForInput
        } else if activeTurn, !pendingTools.isEmpty {
            status = .runningTool
        } else if activeTurn {
            // An open Codex turn means the agent is still producing/thinking.
            // Do not gate this on mtime: long model/tool runs can be quiet
            // for minutes while Codex itself still says “Working”. Closed / 
            // aborted turns clear `activeTurn` above.
            status = .working
        } else {
            status = .completed
        }

        let preview = title
            ?? latestAssistantMessage
            ?? latestUserMessage
            ?? firstUserMessage
            ?? file.lastPathComponent
        // Determine where this session lives so tapping it reopens it correctly.
        //
        // source = "cli"     → user ran `codex` in a terminal; focus via tty/terminal.
        // source = "exec"    → Codex Mac app spawned the session; deep-link back into it.
        // source = "vscode"  → VS Code extension; open the editor, not the Mac app.
        // source = subagent  → spawned by another agent; inherit no special routing.
        // source = MISSING   → old format; treat as CLI (no reliable deep link).
        let isMacAppSession = source == "exec"
        let isVSCodeSession = source == "vscode"

        let launchURL: String? = isMacAppSession ? "codex://threads/\(threadID)" : nil
        let appBundleID: String?
        if isMacAppSession {
            appBundleID = "com.openai.codex"
        } else if isVSCodeSession {
            // Don't try to route through the Codex Mac app — just open the
            // folder in whichever VS Code–like editor is running.
            appBundleID = CodexEditorDetector.runningVSCodeBundleID()
        } else {
            appBundleID = nil
        }

        let rawTitle = title
            ?? latestUserMessage
            ?? firstUserMessage
            ?? latestAssistantMessage
            ?? "Codex"

        return DiscoveredSession(
            sessionKey: "codex:\(threadID)",
            sourceKind: .transcript,
            id: "codex-\(threadID)",
            title: DiscoveryHelpers.truncated(rawTitle, limit: 120),
            cwd: cwd,
            harness: .codex,
            status: status,
            preview: DiscoveryHelpers.truncated(preview, limit: 120),
            lastActivity: latestTimestamp,
            pid: nil,
            terminalName: nil,
            tty: nil,
            appBundleID: appBundleID,
            launchURL: launchURL
        )
    }
}

// MARK: - Codex App Server

actor CodexAppServerSource {
    static let shared = CodexAppServerSource()

    private enum AppServerError: Error {
        case missingExecutable
        case missingSocket
        case timeout
    }

    private let port = 41241
    private var process: Process?
    private var websocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var requestSequence = 0
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]

    fileprivate func scan() async -> [DiscoveredSession] {
        do {
            try await ensureConnected()
            let response = try await sendRequest(
                method: "thread/list",
                params: [
                    "archived": false,
                    "limit": 30,
                    "sortKey": "updated_at"
                ],
                timeout: 1.5
            )
            let rawThreads = response["data"] as? [[String: Any]] ?? []
            return rawThreads.compactMap(parseThread)
        } catch {
            disconnect(terminateProcess: false)
            return []
        }
    }

    func stop() {
        disconnect(terminateProcess: true)
    }

    private func ensureConnected() async throws {
        if websocket != nil { return }

        if try await connect() {
            return
        }

        guard let executable = CodexExecutableResolver.resolve() else {
            throw AppServerError.missingExecutable
        }

        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: executable)
        launched.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        launched.standardOutput = Pipe()
        launched.standardError = Pipe()
        try launched.run()
        process = launched

        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if try await connect() {
                return
            }
        }

        process?.terminate()
        process = nil
        throw AppServerError.missingSocket
    }

    private func connect() async throws -> Bool {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        websocket = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            _ = try await sendRequest(method: "initialize", params: Self.initializeParams, timeout: 0.75)
            try await sendNotification(method: "initialized", params: [:])
            return true
        } catch {
            disconnect(terminateProcess: false)
            return false
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let websocket else { return }
            do {
                let message = try await websocket.receive()
                handle(message)
            } catch {
                disconnect(terminateProcess: false)
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idValue = json["id"] else {
            return
        }

        let id = DiscoveryHelpers.string(idValue) ?? "\(idValue)"
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }

        if let result = json["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else if json["result"] is NSNull {
            continuation.resume(returning: [:])
        } else if let error = json["error"] as? [String: Any] {
            let message = DiscoveryHelpers.string(error["message"]) ?? "Codex app-server error"
            continuation.resume(throwing: NSError(domain: "CodexAppServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ]))
        } else {
            continuation.resume(returning: [:])
        }
    }

    private func sendRequest(method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard websocket != nil else { throw AppServerError.missingSocket }
        requestSequence += 1
        let id = "\(requestSequence)"
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? "{}"

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task { [id, timeout] in
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                self.expireRequest(id)
            }
            Task { [text, id] in
                await self.sendMessage(text, id: id)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        guard let websocket else { throw AppServerError.missingSocket }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await websocket.send(.string(text))
    }

    private func sendMessage(_ text: String, id: String) async {
        guard let websocket else {
            failRequest(id, error: AppServerError.missingSocket)
            return
        }

        do {
            try await websocket.send(.string(text))
        } catch {
            failRequest(id, error: error)
        }
    }

    private func expireRequest(_ id: String) {
        failRequest(id, error: AppServerError.timeout)
    }

    private func failRequest(_ id: String, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func disconnect(terminateProcess: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil

        if terminateProcess {
            process?.terminate()
            process = nil
        }

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: AppServerError.missingSocket)
        }
        pendingResponses.removeAll()
    }

    private func parseThread(_ thread: [String: Any]) -> DiscoveredSession? {
        guard let threadID = DiscoveryHelpers.string(thread["id"]) else { return nil }
        let cwd = DiscoveryHelpers.string(thread["cwd"]) ?? DiscoveryHelpers.string(thread["path"]) ?? NSHomeDirectory()
        let name = DiscoveryHelpers.string(thread["name"])
        let preview = DiscoveryHelpers.string(thread["preview"]) ?? name ?? "Codex App"
        let updatedAt = DiscoveryHelpers.parseDate(thread["updatedAt"]) ?? Date()
        let status = parseStatus(thread["status"] as? [String: Any])

        return DiscoveredSession(
            sessionKey: "codex:\(threadID)",
            sourceKind: .appServer,
            id: "codex-\(threadID)",
            title: DiscoveryHelpers.truncated(name ?? preview, limit: 120),
            cwd: cwd,
            harness: .codex,
            status: status,
            preview: DiscoveryHelpers.truncated(preview, limit: 120),
            lastActivity: updatedAt,
            pid: nil,
            terminalName: nil,
            tty: nil,
            appBundleID: "com.openai.codex",
            launchURL: "codex://threads/\(threadID)"
        )
    }

    private func parseStatus(_ status: [String: Any]?) -> SessionStatusKind {
        let type = DiscoveryHelpers.string(status?["type"])?.lowercased()
        switch type {
        case "waiting_for_approval", "approval", "needs_approval":
            return .waitingForApproval
        case "waiting_for_input", "input_required", "needs_input":
            return .waitingForInput
        case "running_tool", "tool", "mcp_tool":
            return .runningTool
        case "processing", "running", "busy", "working":
            return .working
        case "active":
            return .active
        case "completed", "complete", "done":
            return .completed
        case "error", "failed":
            return .error
        default:
            return .completed
        }
    }

    private nonisolated static var initializeParams: [String: Any] {
        [
            "clientInfo": [
                "name": "Clanker",
                "version": "0.1.0"
            ],
            "capabilities": [
                "experimentalApi": true,
                "optOutNotificationMethods": [
                    "item/agentMessage/delta",
                    "item/thinking/delta"
                ]
            ]
        ]
    }
}

private enum CodexExecutableResolver {
    static func resolve() -> String? {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let path = ProcessRunner.run("/usr/bin/which", ["codex"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Claude Sources

private struct ClaudeSessionSource {
    let snapshot: ProcessSnapshot

    func scan() -> [DiscoveredSession] {
        scanLive() + scanHistorical()
    }

    func scanLive() -> [DiscoveredSession] {
        liveSessionFiles()
    }

    func scanHistorical() -> [DiscoveredSession] {
        transcriptFallbacks()
    }

    private func liveSessionFiles() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(parseClaudeSessionFile)
    }

    private func parseClaudeSessionFile(_ file: URL) -> DiscoveredSession? {
        guard let raw = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let pid = DiscoveryHelpers.int(json["pid"]),
              ProcessRunner.isAlive(pid: pid) else {
            return nil
        }

        let sessionID = DiscoveryHelpers.string(json["sessionId"]) ?? file.deletingPathExtension().lastPathComponent
        let cwd = DiscoveryHelpers.string(json["cwd"]) ?? ProcessRunner.cwd(for: pid) ?? NSHomeDirectory()
        let updatedAt = DiscoveryHelpers.parseDate(json["updatedAt"]) ?? Date()
        let statusValue = DiscoveryHelpers.string(json["status"])?.lowercased()
        let transcript = ClaudeTranscriptParser.parse(sessionID: sessionID, cwd: cwd)

        let status: SessionStatusKind
        if transcript.blockedOnUser || statusValue == "waiting" {
            status = .waitingForInput
        } else if statusValue == "busy" {
            status = .thinking
        } else {
            status = .idle
        }

        let process = snapshot.byPID[pid]
        let terminal = process.flatMap { snapshot.terminalContext(for: $0) }
        let tty = process?.tty
        let title = DiscoveryHelpers.string(json["name"])
            ?? transcript.title
            ?? "Claude Code"

        return DiscoveredSession(
            sessionKey: "claude:\(sessionID)",
            sourceKind: .transcript,
            id: "claude-\(sessionID)",
            title: title,
            cwd: cwd,
            harness: .claude,
            status: status,
            preview: transcript.preview ?? "Claude Code PID \(pid)",
            lastActivity: transcript.lastActivity ?? updatedAt,
            pid: pid,
            terminalName: terminal?.name,
            tty: tty,
            appBundleID: terminal?.bundleID,
            launchURL: nil
        )
    }

    private func transcriptFallbacks() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        return DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 24 * 60 * 60, limit: 80)
            .compactMap { file, modified in
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard let transcript = ClaudeTranscriptParser.parse(file: file, fallbackSessionID: sessionID) else {
                    return nil
                }
                let cwd = transcript.cwd ?? decodeClaudeProjectSlug(file.deletingLastPathComponent().lastPathComponent)
                let status: SessionStatusKind
                if transcript.blockedOnUser {
                    status = .waitingForInput
                } else if Date().timeIntervalSince(modified) < 2 * 60 {
                    status = .active
                } else {
                    status = .completed
                }

                return DiscoveredSession(
                    sessionKey: "claude:\(transcript.sessionID)",
                    sourceKind: .transcript,
                    id: "claude-\(transcript.sessionID)",
                    title: transcript.title ?? "Claude Code",
                    cwd: cwd,
                    harness: .claude,
                    status: status,
                    preview: transcript.preview ?? file.lastPathComponent,
                    lastActivity: transcript.lastActivity ?? modified,
                    pid: nil,
                    terminalName: nil,
                    tty: nil,
                    appBundleID: nil,
                    launchURL: nil
                )
            }
    }

    private func decodeClaudeProjectSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }
}

private struct ClaudeTranscriptSummary: Sendable {
    var sessionID: String
    var cwd: String?
    var title: String?
    var preview: String?
    var lastActivity: Date?
    var blockedOnUser: Bool
}

private enum ClaudeTranscriptParser {
    static func parse(sessionID: String, cwd: String) -> ClaudeTranscriptSummary {
        let slug = projectSlug(for: cwd)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(sessionID).jsonl")
        return parse(file: file, fallbackSessionID: sessionID)
            ?? ClaudeTranscriptSummary(sessionID: sessionID, cwd: cwd, title: nil, preview: nil, lastActivity: nil, blockedOnUser: false)
    }

    static func parse(file: URL, fallbackSessionID: String) -> ClaudeTranscriptSummary? {
        guard let content = DiscoveryHelpers.readTail(file, maxBytes: 4 * 1024 * 1024) else {
            return nil
        }

        var sessionID = fallbackSessionID
        var cwd: String?
        var title: String?
        var preview: String?
        var lastActivity: Date?
        var seenToolResults = Set<String>()
        var blockedOnUser = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let json = DiscoveryHelpers.jsonObject(fromLine: line) else { continue }
            sessionID = DiscoveryHelpers.string(json["sessionId"]) ?? sessionID
            cwd = DiscoveryHelpers.string(json["cwd"]) ?? cwd
            lastActivity = lastActivity ?? DiscoveryHelpers.parseDate(json["timestamp"])

            if title == nil, json["type"] as? String == "ai-title" {
                title = DiscoveryHelpers.string(json["aiTitle"])
            }

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "tool_result",
                       let id = DiscoveryHelpers.string(block["tool_use_id"]) {
                        seenToolResults.insert(id)
                    }
                }
            }

            guard json["isSidechain"] as? Bool != true,
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            if preview == nil {
                preview = DiscoveryHelpers.messageText(message)
            }

            if !blockedOnUser,
               json["type"] as? String == "assistant",
               message["stop_reason"] as? String == "tool_use",
               let blocks = message["content"] as? [[String: Any]] {
                let pending = blocks.compactMap { block -> (String, String)? in
                    guard block["type"] as? String == "tool_use",
                          let id = DiscoveryHelpers.string(block["id"]),
                          !seenToolResults.contains(id) else {
                        return nil
                    }
                    return (DiscoveryHelpers.string(block["name"]) ?? "", id)
                }
                blockedOnUser = pending.contains { $0.0 == "AskUserQuestion" } || !pending.isEmpty
            }

            if preview != nil, title != nil, cwd != nil, lastActivity != nil {
                break
            }
        }

        return ClaudeTranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            preview: preview.map { DiscoveryHelpers.truncated($0, limit: 120) },
            lastActivity: lastActivity,
            blockedOnUser: blockedOnUser
        )
    }

    private static func projectSlug(for path: String) -> String {
        var output = ""
        for scalar in path.unicodeScalars {
            let value = scalar.value
            let isAlnum = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            output.append(isAlnum ? Character(scalar) : "-")
        }
        return output
    }
}

// MARK: - Pi Source

private struct PiSessionSource {
    let snapshot: ProcessSnapshot

    func scan() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        return DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 24 * 60 * 60, limit: 80)
            .compactMap(parsePiSession)
    }

    private func parsePiSession(_ file: URL, modified: Date) -> DiscoveredSession? {
        guard let content = DiscoveryHelpers.readUTF8File(file, maxBytes: 12 * 1024 * 1024) else {
            return nil
        }

        var sessionID = file.deletingPathExtension().lastPathComponent
        var cwd: String?
        var name: String?
        var firstUserMessage: String?
        var latestUserMessage: String?
        var totalCost = 0.0
        var totalTokens = 0
        var modelWeights: [String: Double] = [:]
        var toolCallCount = 0
        var turnIsOpen = false
        var latestAssistantStopReason: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = DiscoveryHelpers.jsonObject(fromLine: line) else { continue }
            let timestamp = DiscoveryHelpers.parseDate(json["timestamp"])
            firstTimestamp = firstTimestamp ?? timestamp
            lastTimestamp = timestamp ?? lastTimestamp

            switch json["type"] as? String {
            case "session":
                sessionID = DiscoveryHelpers.string(json["id"]) ?? sessionID
                cwd = DiscoveryHelpers.string(json["cwd"]) ?? cwd
            case "session_info":
                name = DiscoveryHelpers.string(json["name"]) ?? name
            case "message":
                let message = json["message"] as? [String: Any] ?? [:]
                let role = DiscoveryHelpers.string(message["role"])
                if role == "user" {
                    if let text = DiscoveryHelpers.userFacingMessageText(message) {
                        firstUserMessage = firstUserMessage ?? text
                        latestUserMessage = text
                    }
                    latestAssistantStopReason = nil
                    turnIsOpen = true
                }
                if role == "assistant" {
                    latestAssistantStopReason = DiscoveryHelpers.string(message["stopReason"])?.lowercased()
                    switch latestAssistantStopReason {
                    case "stop", "aborted", "error":
                        turnIsOpen = false
                    case "tooluse", "tool_use":
                        turnIsOpen = true
                    default:
                        turnIsOpen = true
                    }

                    if let usage = message["usage"] as? [String: Any] {
                        totalTokens += DiscoveryHelpers.int(usage["totalTokens"]) ?? 0
                        if let cost = usage["cost"] as? [String: Any],
                           let value = DiscoveryHelpers.double(cost["total"]) {
                            totalCost += value
                            if let model = DiscoveryHelpers.string(message["model"]) {
                                modelWeights[model, default: 0] += value
                            }
                        } else if let model = DiscoveryHelpers.string(message["model"]) {
                            modelWeights[model, default: 0] += 1
                        }
                    }
                    if let blocks = message["content"] as? [[String: Any]] {
                        toolCallCount += blocks.filter { $0["type"] as? String == "toolCall" }.count
                    }
                } else if role == "toolResult" {
                    turnIsOpen = true
                }
            default:
                break
            }
        }

        let cwdValue = cwd ?? decodePiProjectPath(file.deletingLastPathComponent().lastPathComponent)
        let primaryModel = modelWeights.max(by: { $0.value < $1.value })?.key
        let previewParts = [
            primaryModel,
            totalTokens > 0 ? "\(DiscoveryHelpers.formatTokens(totalTokens)) tokens" : nil,
            totalCost > 0 ? String(format: "$%.2f", totalCost) : nil,
            toolCallCount > 0 ? "\(toolCallCount) tools" : nil
        ].compactMap { $0 }
        let preview = previewParts.isEmpty ? file.lastPathComponent : previewParts.joined(separator: " · ")

        let title = usefulPiSessionName(name)
            ?? latestUserMessage
            ?? firstUserMessage
            ?? "Pi"

        return DiscoveredSession(
            sessionKey: "pi:\(sessionID)",
            sourceKind: .transcript,
            id: "pi-\(sessionID)",
            title: title,
            cwd: cwdValue,
            harness: .pi,
            status: piStatus(
                turnIsOpen: turnIsOpen,
                latestAssistantStopReason: latestAssistantStopReason,
                modified: modified
            ),
            preview: DiscoveryHelpers.truncated(preview, limit: 120),
            lastActivity: lastTimestamp ?? firstTimestamp ?? modified,
            pid: nil,
            terminalName: nil,
            tty: nil,
            appBundleID: nil,
            launchURL: nil
        )
    }

    private func decodePiProjectPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }

    private func piStatus(
        turnIsOpen: Bool,
        latestAssistantStopReason: String?,
        modified: Date
    ) -> SessionStatusKind {
        if latestAssistantStopReason == "error" {
            return .error
        }
        if turnIsOpen {
            return .working
        }
        return Date().timeIntervalSince(modified) < 10 * 60 ? .active : .completed
    }

    private func usefulPiSessionName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let modelPrefixes = ["claude-", "gpt-", "o3", "o4", "gemini-", "llama-", "mistral-"]
        if modelPrefixes.contains(where: normalized.hasPrefix) { return nil }
        if normalized.contains(" tokens") || normalized.contains(" tools") || normalized.contains(" · ") {
            return nil
        }

        return value
    }
}

// MARK: - Running Apps

@MainActor
private enum MacAppSource {
    static func scan() -> [DiscoveredSession] {
        var sessions: [DiscoveredSession] = []
        let apps = NSWorkspace.shared.runningApplications

        if let codex = apps.first(where: { $0.bundleIdentifier == "com.openai.codex" }) {
            sessions.append(DiscoveredSession(
                sessionKey: "codex:app-running",
                sourceKind: .app,
                id: "codex-app-running",
                title: "Codex",
                cwd: NSHomeDirectory(),
                harness: .codex,
                status: .active,
                preview: "Codex app is running",
                lastActivity: codex.launchDate ?? Date(),
                pid: Int(codex.processIdentifier),
                terminalName: nil,
                tty: nil,
                appBundleID: codex.bundleIdentifier,
                launchURL: nil
            ))
        }

        return sessions
    }
}

// MARK: - Process Helpers

private func harness(for row: ProcessRow) -> HarnessID? {
    if isCodexProcess(row) { return .codex }
    if isClaudeProcess(row) { return .claude }
    if isPiProcess(row) { return .pi }
    return nil
}

private func isHarnessProcess(_ row: ProcessRow) -> Bool {
    harness(for: row) != nil
}

private func isCodexProcess(_ row: ProcessRow) -> Bool {
    let command = row.command.lowercased()
    let executable = row.executableName.lowercased()
    guard !isCodexAppServerProcess(row) else { return false }
    return executable == "codex"
        || command.contains("@openai/codex")
        || command.contains("@openai+codex")
        || command.contains("/codex/codex")
        || command.contains("/codex.app/contents/resources/codex")
}

private func isCodexAppServerProcess(_ row: ProcessRow) -> Bool {
    row.command.lowercased().contains(" app-server")
}

private func isClaudeProcess(_ row: ProcessRow) -> Bool {
    let command = row.command.lowercased()
    let executable = row.executableName.lowercased()
    return executable == "claude"
        || executable == "claude-code"
        || command.contains("@anthropic-ai/claude-code")
        || command.contains("/claude-code/")
        || command.contains("/claude ")
}

private func isPiProcess(_ row: ProcessRow) -> Bool {
    let command = row.command.lowercased()
    let executable = row.executableName.lowercased()
    return executable == "pi"
        || command.hasSuffix("/bin/pi")
        || command.contains("/bin/pi ")
        || command.contains("/pi/agent/")
}

// MARK: - Shared Helpers

private enum DiscoveryHelpers {
    static func normalizedTTY(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        if trimmed.hasPrefix("tty") { return "/dev/\(trimmed)" }
        return "/dev/tty\(trimmed)"
    }

    static func normalizedPath(_ path: String) -> String {
        let expanded = expandHome(path)
        let standardized = (expanded as NSString).standardizingPath
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    static func expandHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }

    static func isUsefulPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "/" && trimmed != "~"
    }

    static func projectName(for cwd: String) -> String {
        let expanded = expandHome(cwd)
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        return name.isEmpty ? expanded : name
    }

    static func abbreviateHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func identifierSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/dev/", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func recentJSONLFiles(at root: URL, maxAge: TimeInterval, limit: Int) -> [(URL, Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-maxAge)
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile != false,
                      let modified = values?.contentModificationDate,
                      modified >= cutoff else {
                    return nil
                }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    static func readUTF8File(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    static func readTail(_ url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    static func jsonObject(fromLine line: Substring) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let raw = value as? Double {
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = string(value) else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }

        return ISO8601DateFormatter().date(from: text)
    }

    static func compactText(_ value: Any?) -> String? {
        if let text = string(value) {
            return truncated(text, limit: 160)
        }
        if let array = value as? [Any] {
            let text = array.compactMap(compactText).joined(separator: "\n")
            return text.nonEmpty.map { truncated($0, limit: 160) }
        }
        if let object = value as? [String: Any] {
            return compactText(object["text"] ?? object["content"] ?? object["message"])
        }
        return nil
    }

    static func messageText(_ message: [String: Any]) -> String? {
        if let text = string(message["content"]) {
            return truncated(text, limit: 160)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                if let text = string(block["text"]) { return text }
                if let content = string(block["content"]) { return content }
                return nil
            }.joined(separator: "\n")
            return text.nonEmpty.map { truncated($0, limit: 160) }
        }
        return nil
    }

    static func userFacingMessageText(_ message: [String: Any]) -> String? {
        guard let text = messageText(message) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<skill "),
              !trimmed.hasPrefix("<skill-name>"),
              !trimmed.hasPrefix("<system-reminder>") else {
            return nil
        }
        return trimmed
    }

    static func normalizedToolName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func truncated(_ value: String, limit: Int) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

// MARK: - Codex origin helpers

extension ProcessSnapshot {
    /// Returns `true` when any ancestor of `pid` in the process tree has a
    /// command path that includes `/Codex.app/`, indicating the process was
    /// spawned by the Codex desktop Mac app rather than a terminal shell.
    func isInsideCodexMacApp(pid: Int) -> Bool {
        var current = pid
        var depth = 0
        var seen = Set<Int>()
        while current > 1, depth < 50, seen.insert(current).inserted {
            guard let row = byPID[current] else { break }
            if row.command.contains("/Codex.app/") { return true }
            current = row.ppid
            depth += 1
        }
        return false
    }
}

/// Detects which VS Code–like editor is currently running so transcript
/// sessions with `source = "vscode"` route to the right app.
private enum CodexEditorDetector {
    /// Bundle IDs for editors that embed the Codex VS Code extension.
    private static let candidates = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.codeium.windsurf"
    ]

    /// Returns the bundle ID of the first matching editor that has a running
    /// process, or `nil` if none is detected. Called on a background thread
    /// via process-list inspection rather than `NSRunningApplication` to avoid
    /// a main-thread requirement.
    static func runningVSCodeBundleID() -> String? {
        let output = ProcessRunner.run("/bin/ps", ["-axo", "command="])
        let commands = output.split(separator: "\n").map(String.init)
        for candidate in candidates {
            let appDir = candidate.components(separatedBy: ".").last.map { $0.capitalized } ?? ""
            if commands.contains(where: { $0.contains(".app/Contents/MacOS/") && ($0.contains("/\(appDir).app/") || $0.localizedCaseInsensitiveContains(appDir)) }) {
                return candidate
            }
        }
        return nil
    }
}

/// Lightweight index over recent Codex transcripts so live Mac-app processes
/// can be matched to a `codex://threads/{id}` deep link via their working dir.
final class CodexTranscriptIndex: @unchecked Sendable {
    static let shared = CodexTranscriptIndex()

    private let lock = NSLock()
    private var cwdToThreadID: [String: String] = [:]
    private var builtAt: Date = .distantPast
    private let ttl: TimeInterval = 60

    /// Returns the thread ID of the most recent Mac-app transcript (`source =
    /// "exec"`) whose `cwd` matches `path`, rebuilding the index when stale.
    func threadID(forCWD path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if Date().timeIntervalSince(builtAt) > ttl {
            rebuild()
        }
        let key = (path as NSString).standardizingPath
        return cwdToThreadID[key]
    }

    private func rebuild() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 4 * 60 * 60, limit: 200)
        var map: [String: (threadID: String, date: Date)] = [:]

        for (file, modified) in files {
            guard file.lastPathComponent.hasPrefix("rollout-"),
                  let content = DiscoveryHelpers.readUTF8File(file, maxBytes: 2048) else {
                continue
            }
            // Only read the first few lines to extract session_meta cheaply.
            for line in content.split(separator: "\n", omittingEmptySubsequences: true).prefix(8) {
                guard let json = DiscoveryHelpers.jsonObject(fromLine: line),
                      json["type"] as? String == "session_meta" else { continue }
                let payload = json["payload"] as? [String: Any] ?? [:]
                guard let source = DiscoveryHelpers.string(payload["source"]),
                      source == "exec" else { break }
                guard let threadID = DiscoveryHelpers.string(payload["id"]),
                      let cwd = DiscoveryHelpers.string(payload["cwd"]) else { break }
                let key = (cwd as NSString).standardizingPath
                if let existing = map[key], existing.date >= modified { break }
                map[key] = (threadID, modified)
                break
            }
        }

        cwdToThreadID = map.mapValues(\.threadID)
        builtAt = Date()
    }
}

private enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) -> String {
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

    static func cwd(for pid: Int) -> String? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.first == "n" else { return nil }
                return String(line.dropFirst())
            }
            .first
    }

    /// Pid of the foreground process group leader for `tty`. This is
    /// `tpgid` in `ps(1)` — the group `kill(0, ...)` would deliver SIGINT to
    /// when the user presses ^C. It's the most reliable signal for "what's
    /// the user actually interacting with in this terminal right now",
    /// independent of how many child harnesses / wrappers are in the tree.
    ///
    /// `tty` should be the bare name (`ttys003`) or full path (`/dev/ttys003`);
    /// we normalize to bare for `ps`.
    static func foregroundPID(for tty: String) -> Int? {
        let bare = tty.replacingOccurrences(of: "/dev/", with: "")
        let output = run("/bin/ps", ["-t", bare, "-o", "pid=,tpgid=,stat="])
        // Lines look like: " 7871  7871 S+". Foreground row has pid == tpgid
        // and a `+` flag in stat. Either condition alone is sufficient on
        // macOS but we apply both for paranoia.
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int(parts[0]),
                  let tpgid = Int(parts[1]) else { continue }
            if pid == tpgid && parts[2].contains("+") {
                return pid
            }
        }
        return nil
    }

    static func startDate(for pid: Int) -> Date? {
        let output = run("/bin/ps", ["-p", String(pid), "-o", "lstart="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: output)
    }

    static func isAlive(pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), 0) == 0
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
