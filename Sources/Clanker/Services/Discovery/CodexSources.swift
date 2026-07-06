import Foundation

// MARK: - Session index (thread titles)

/// Codex maintains `~/.codex/session_index.jsonl` mapping thread ids to the
/// names shown in its own UI ("Fix onboarding flow", …). Those are the best
/// titles available — far better than reconstructing one from the transcript.
enum CodexSessionIndex {
    private static let cache = FileParseCache<[String: String]>()

    static func threadNames(indexFile: URL? = nil) -> [String: String] {
        let file = indexFile ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        return cache.value(for: file, parse: parse) ?? [:]
    }

    static func parse(_ url: URL) -> [String: String]? {
        // The index is append-only; the tail holds the most recent entries
        // and later lines override earlier ones for the same id.
        guard let content = DiscoveryHelpers.readTail(url, maxBytes: 256 * 1024) else {
            return nil
        }
        var names: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = DiscoveryHelpers.jsonObject(fromLine: line),
                  let id = DiscoveryHelpers.string(json["id"]),
                  let name = DiscoveryHelpers.string(json["thread_name"]) else {
                continue
            }
            names[id] = name
        }
        return names
    }
}

// MARK: - Transcripts

struct CodexTranscriptSource {
    let snapshot: ProcessSnapshot

    private static let cache = FileParseCache<DiscoveredSession>()

    func scan() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let threadNames = CodexSessionIndex.threadNames()
        return DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 24 * 60 * 60, limit: 80)
            .compactMap { file, modified in
                Self.cache.value(for: file) { url in
                    Self.parseCodexTranscript(url, modified: modified)
                }
                .map { applyIndexTitle($0, threadNames: threadNames) }
            }
    }

    private func applyIndexTitle(_ session: DiscoveredSession, threadNames: [String: String]) -> DiscoveredSession {
        guard let key = session.sessionKey,
              key.hasPrefix("codex:"),
              let name = threadNames[String(key.dropFirst("codex:".count))] else {
            return session
        }
        var updated = session
        updated.title = DiscoveryHelpers.truncated(name, limit: 120)
        return updated
    }

    static func parseCodexTranscript(_ file: URL, modified: Date) -> DiscoveredSession? {
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
            // for minutes while Codex itself still says "Working". Closed /
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

// MARK: - App server

actor CodexAppServerSource {
    static let shared = CodexAppServerSource()

    private enum AppServerError: Error {
        case missingExecutable
        case missingSocket
        case timeout
        case backoff
    }

    private let port = 41241
    private var process: Process?
    private var websocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var requestSequence = 0
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]

    /// Failure backoff. Without this, every 1s scan tick relaunched
    /// `codex app-server` and burned ~3s waiting for a socket that was never
    /// coming — a subprocess storm on machines where Codex can't serve.
    private var nextAttemptAfter: Date = .distantPast
    private var consecutiveFailures = 0

    /// Thread lists change on user action, not every second; a short result
    /// cache keeps the websocket chatter proportionate.
    private var lastThreads: [DiscoveredSession] = []
    private var lastThreadsAt: Date = .distantPast
    private let resultTTL: TimeInterval = 5

    /// Actor methods interleave at suspension points; without this, a scan
    /// tick arriving while a previous connect is mid-await could launch a
    /// second app-server process.
    private var scanInFlight = false

    func scan() async -> [DiscoveredSession] {
        if Date().timeIntervalSince(lastThreadsAt) < resultTTL {
            return lastThreads
        }
        guard !scanInFlight else {
            return lastThreads
        }
        guard Date() >= nextAttemptAfter else {
            return websocket == nil ? [] : lastThreads
        }

        scanInFlight = true
        defer { scanInFlight = false }

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
            consecutiveFailures = 0
            lastThreads = rawThreads.compactMap(parseThread)
            lastThreadsAt = Date()
            return lastThreads
        } catch {
            disconnect(terminateProcess: false)
            registerFailure()
            return []
        }
    }

    func stop() {
        disconnect(terminateProcess: true)
    }

    private func registerFailure() {
        consecutiveFailures += 1
        let delay = min(pow(2, Double(consecutiveFailures)) * 15, 600)
        nextAttemptAfter = Date().addingTimeInterval(delay)
        lastThreads = []
        lastThreadsAt = .distantPast
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
              let idValue = json["id"],
              // Server-initiated *requests* also carry an id; only messages
              // without a method are responses to us. Confusing the two
              // resumes the wrong continuation and orphans the real reply.
              json["method"] == nil else {
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
            ?? CodexSessionIndex.threadNames()[threadID]
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

enum CodexExecutableResolver {
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

/// Detects which VS Code–like editor is currently running so transcript
/// sessions with `source = "vscode"` route to the right app.
enum CodexEditorDetector {
    /// Editors that embed the Codex VS Code extension, mapped to the .app
    /// folder name their processes actually run from. (Deriving the folder
    /// from the bundle-id tail breaks: "VSCode".capitalized is "Vscode" and
    /// Cursor's todesktop id has no name in it at all.)
    private static let candidates: [(bundleID: String, appFolder: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "Visual Studio Code - Insiders"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("com.codeium.windsurf", "Windsurf")
    ]

    /// Returns the bundle ID of the first matching editor that has a running
    /// process, or `nil` if none is detected. Uses process-list inspection
    /// rather than `NSRunningApplication` to avoid a main-thread requirement.
    static func runningVSCodeBundleID() -> String? {
        let output = ProcessRunner.run("/bin/ps", ["-axo", "command="]).lowercased()
        for (bundleID, appFolder) in candidates {
            if output.contains("/\(appFolder.lowercased()).app/contents/macos/") {
                return bundleID
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
