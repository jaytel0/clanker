import Foundation

// MARK: - Claude Code sessions

struct ClaudeSessionSource {
    let snapshot: ProcessSnapshot

    private static let transcriptCache = FileParseCache<ClaudeTranscriptSummary>()

    func scan() -> [DiscoveredSession] {
        scanLive() + scanHistorical()
    }

    /// Claude Code writes `~/.claude/sessions/<pid>.json` for every live
    /// process, including its own `status` ("busy" / "waiting") heartbeat.
    /// That heartbeat is the single most reliable state signal we have.
    func scanLive() -> [DiscoveredSession] {
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

    func scanHistorical() -> [DiscoveredSession] {
        transcriptFallbacks()
    }

    private func parseClaudeSessionFile(_ file: URL) -> DiscoveredSession? {
        guard let raw = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let pid = DiscoveryHelpers.int(json["pid"]),
              ProcessRunner.isAlive(pid: pid) else {
            return nil
        }

        // A claude process spawned by another agent (subprocess `claude -p`,
        // companion tooling) writes a session file too — it's the parent
        // agent's work, not a session the user started.
        if let row = snapshot.byPID[pid], snapshot.isAgentSpawned(row) {
            return nil
        }

        let sessionID = DiscoveryHelpers.string(json["sessionId"]) ?? file.deletingPathExtension().lastPathComponent
        let cwd = DiscoveryHelpers.string(json["cwd"]) ?? ProcessRunner.cwd(for: pid) ?? NSHomeDirectory()
        let updatedAt = DiscoveryHelpers.parseDate(json["updatedAt"]) ?? Date()
        let statusUpdatedAt = DiscoveryHelpers.parseDate(json["statusUpdatedAt"]) ?? updatedAt
        let statusValue = DiscoveryHelpers.string(json["status"])?.lowercased()
        let transcript = transcriptSummary(sessionID: sessionID, cwd: cwd)

        // A "busy" heartbeat that stopped updating is a dead turn (crash,
        // suspend); don't let it pin the row to Thinking forever.
        let heartbeatFresh = Date().timeIntervalSince(statusUpdatedAt) < 3 * 60
        let transcriptAge = transcript.lastActivity.map { Date().timeIntervalSince($0) }

        let status: SessionStatusKind
        if transcript.blockedOnQuestion || statusValue == "waiting" {
            status = .waitingForInput
        } else if statusValue == "busy", heartbeatFresh {
            status = transcript.pendingToolName != nil ? .runningTool : .thinking
        } else if transcript.pendingToolName != nil {
            // No live heartbeat to disambiguate. A tool call with recent
            // transcript movement is still executing; one that's gone quiet
            // is almost always a permission prompt.
            if let transcriptAge, transcriptAge > 2 * 60 {
                status = .waitingForApproval
            } else {
                status = .runningTool
            }
        } else if snapshot.aggregateCPU(of: pid) >= TerminalProcessSource.workingCPUThreshold {
            status = .working
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
                guard let transcript = Self.transcriptCache.value(for: file, parse: {
                    ClaudeTranscriptParser.parse(file: $0, fallbackSessionID: sessionID)
                }) else {
                    return nil
                }
                let cwd = transcript.cwd ?? decodeClaudeProjectSlug(file.deletingLastPathComponent().lastPathComponent)
                let status: SessionStatusKind
                if transcript.blockedOnQuestion {
                    status = .waitingForInput
                } else if Date().timeIntervalSince(modified) < 2 * 60 {
                    status = transcript.pendingToolName != nil ? .runningTool : .active
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

    private func transcriptSummary(sessionID: String, cwd: String) -> ClaudeTranscriptSummary {
        let slug = ClaudeTranscriptParser.projectSlug(for: cwd)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(sessionID).jsonl")
        return Self.transcriptCache.value(for: file, parse: {
            ClaudeTranscriptParser.parse(file: $0, fallbackSessionID: sessionID)
        }) ?? ClaudeTranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: nil,
            preview: nil,
            lastActivity: nil,
            blockedOnQuestion: false,
            pendingToolName: nil
        )
    }

    private func decodeClaudeProjectSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }
}

// MARK: - Transcript parsing

struct ClaudeTranscriptSummary: Sendable {
    var sessionID: String
    var cwd: String?
    var title: String?
    var preview: String?
    var lastActivity: Date?
    /// A question tool (AskUserQuestion, ExitPlanMode) is awaiting an answer —
    /// the one transcript shape that genuinely means "needs input".
    var blockedOnQuestion: Bool
    /// Some tool call has no result yet. While the transcript is still moving
    /// that means "running a tool"; once it goes quiet it's almost always a
    /// permission prompt.
    var pendingToolName: String?
}

enum ClaudeTranscriptParser {
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
        var blockedOnQuestion = false
        var pendingToolName: String?
        var resolvedToolState = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let json = DiscoveryHelpers.jsonObject(fromLine: line) else { continue }
            sessionID = DiscoveryHelpers.string(json["sessionId"]) ?? sessionID
            cwd = DiscoveryHelpers.string(json["cwd"]) ?? cwd
            lastActivity = lastActivity ?? DiscoveryHelpers.parseDate(json["timestamp"])

            if title == nil, json["type"] as? String == "ai-title" {
                title = DiscoveryHelpers.string(json["aiTitle"])
            }

            if json["type"] as? String == "user",
               json["isSidechain"] as? Bool != true,
               // Meta lines (caveats, local-command output) are injected by
               // the harness mid-turn; they are not the user speaking and
               // must not count as a turn boundary.
               json["isMeta"] as? Bool != true,
               let message = json["message"] as? [String: Any] {
                if let blocks = message["content"] as? [[String: Any]] {
                    var sawToolResult = false
                    for block in blocks {
                        if block["type"] as? String == "tool_result",
                           let id = DiscoveryHelpers.string(block["tool_use_id"]) {
                            seenToolResults.insert(id)
                            sawToolResult = true
                        }
                    }
                    // A real user message (not tool plumbing) is a turn
                    // boundary: anything older can't be pending anymore.
                    if !sawToolResult {
                        resolvedToolState = true
                    }
                } else if DiscoveryHelpers.string(message["content"]) != nil {
                    resolvedToolState = true
                }
            }

            guard json["isSidechain"] as? Bool != true,
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            if preview == nil {
                preview = DiscoveryHelpers.messageText(message)
            }

            // Only tool state from the *current* turn matters — the reverse
            // walk flips `resolvedToolState` at the newest real user message,
            // so older turns can't contribute pending tools.
            if !resolvedToolState,
               json["type"] as? String == "assistant",
               message["stop_reason"] as? String == "tool_use",
               let blocks = message["content"] as? [[String: Any]] {
                let pending = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "tool_use",
                          let id = DiscoveryHelpers.string(block["id"]),
                          !seenToolResults.contains(id) else {
                        return nil
                    }
                    return DiscoveryHelpers.string(block["name"]) ?? ""
                }
                // A pending question means "answer me"; a pending ordinary
                // tool means the tool is running (or waiting for permission)
                // — NOT that the user owes a reply. Treating every unresolved
                // tool as "needs input" made busy sessions scream for
                // attention.
                blockedOnQuestion = blockedOnQuestion || pending.contains { Self.isQuestionTool($0) }
                pendingToolName = pendingToolName ?? pending.first { !Self.isQuestionTool($0) }
            }

            if preview != nil, title != nil, cwd != nil, lastActivity != nil, resolvedToolState {
                break
            }
        }

        return ClaudeTranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            preview: preview.map { DiscoveryHelpers.truncated($0, limit: 120) },
            lastActivity: lastActivity,
            blockedOnQuestion: blockedOnQuestion,
            pendingToolName: pendingToolName
        )
    }

    static func isQuestionTool(_ name: String) -> Bool {
        let normalized = DiscoveryHelpers.normalizedToolName(name)
        return normalized == "askuserquestion" || normalized == "exitplanmode"
    }

    static func projectSlug(for path: String) -> String {
        var output = ""
        for scalar in path.unicodeScalars {
            let value = scalar.value
            let isAlnum = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            output.append(isAlnum ? Character(scalar) : "-")
        }
        return output
    }
}
