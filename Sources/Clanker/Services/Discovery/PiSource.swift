import Foundation

/// Discovers Pi agent sessions from `~/.pi/agent/sessions` transcripts.
struct PiSessionSource {
    let snapshot: ProcessSnapshot

    /// Content-derived facts, cacheable by (mtime, size). Status is derived
    /// per scan because it depends on wall-clock recency.
    struct PiTranscriptFacts: Sendable {
        var sessionID: String
        var cwd: String?
        var title: String
        var preview: String
        var turnIsOpen: Bool
        var latestAssistantStopReason: String?
        var lastActivity: Date?
    }

    private static let cache = FileParseCache<PiTranscriptFacts>()

    func scan() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        return DiscoveryHelpers.recentJSONLFiles(at: root, maxAge: 24 * 60 * 60, limit: 80)
            .compactMap { file, modified in
                guard let facts = Self.cache.value(for: file, parse: Self.parsePiSession) else {
                    return nil
                }
                return session(from: facts, file: file, modified: modified)
            }
    }

    private func session(from facts: PiTranscriptFacts, file: URL, modified: Date) -> DiscoveredSession {
        let cwd = facts.cwd ?? Self.decodePiProjectPath(file.deletingLastPathComponent().lastPathComponent)

        return DiscoveredSession(
            sessionKey: "pi:\(facts.sessionID)",
            sourceKind: .transcript,
            id: "pi-\(facts.sessionID)",
            title: facts.title,
            cwd: cwd,
            harness: .pi,
            status: Self.status(
                turnIsOpen: facts.turnIsOpen,
                latestAssistantStopReason: facts.latestAssistantStopReason,
                modified: modified
            ),
            preview: facts.preview,
            lastActivity: facts.lastActivity ?? modified,
            pid: nil,
            terminalName: nil,
            tty: nil,
            appBundleID: nil,
            launchURL: nil
        )
    }

    static func parsePiSession(_ file: URL) -> PiTranscriptFacts? {
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

        let primaryModel = modelWeights.max(by: { $0.value < $1.value })?.key
        let previewParts = [
            primaryModel,
            totalTokens > 0 ? "\(DiscoveryHelpers.formatTokens(totalTokens)) tokens" : nil,
            totalCost > 0 ? String(format: "$%.2f", totalCost) : nil,
            toolCallCount > 0 ? "\(toolCallCount) tools" : nil
        ].compactMap { $0 }
        let preview = previewParts.isEmpty ? file.lastPathComponent : previewParts.joined(separator: " · ")

        let title = usefulSessionName(name)
            ?? latestUserMessage
            ?? firstUserMessage
            ?? "Pi"

        return PiTranscriptFacts(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            preview: DiscoveryHelpers.truncated(preview, limit: 120),
            turnIsOpen: turnIsOpen,
            latestAssistantStopReason: latestAssistantStopReason,
            lastActivity: lastTimestamp ?? firstTimestamp
        )
    }

    static func decodePiProjectPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }

    static func status(
        turnIsOpen: Bool,
        latestAssistantStopReason: String?,
        modified: Date
    ) -> SessionStatusKind {
        if latestAssistantStopReason == "error" {
            // An error is actionable while it's fresh; an old errored
            // transcript is just history and must not taint a new session
            // that happens to run in the same directory.
            return Date().timeIntervalSince(modified) < 15 * 60 ? .error : .completed
        }
        if turnIsOpen {
            // Trust an open turn only while the transcript is still moving;
            // a killed pi process leaves the last turn open forever.
            return Date().timeIntervalSince(modified) < 10 * 60 ? .working : .completed
        }
        return Date().timeIntervalSince(modified) < 10 * 60 ? .active : .completed
    }

    private static func usefulSessionName(_ value: String?) -> String? {
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
