import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

actor SessionTitleService {
    static let shared = SessionTitleService()

    private var generatedTitles: [String: String] = [:]
    private var inFlightSignatures = Set<String>()
    private var disabledUntil: Date?

    func applyCachedTitles(to sessions: [AgentSession]) -> [AgentSession] {
        sessions.map { session in
            var copy = session
            let context = SessionTitleContext(session: copy)
            copy.title = generatedTitles[context.signature]
                ?? SessionTitleHeuristics.title(for: context)
            return copy
        }
    }

    func generateMissingTitles(for sessions: [AgentSession]) async {
        if let disabledUntil, disabledUntil > Date() {
            return
        }

        let contexts = sessions
            .prefix(12)
            .map(SessionTitleContext.init(session:))
            .filter(\.hasUsefulModelInput)

        var generatedCount = 0
        for context in contexts where generatedCount < 4 {
            guard generatedTitles[context.signature] == nil,
                  !inFlightSignatures.contains(context.signature) else {
                continue
            }

            inFlightSignatures.insert(context.signature)
            defer { inFlightSignatures.remove(context.signature) }

            guard let title = await generateTitle(for: context) else {
                continue
            }

            generatedTitles[context.signature] = title
            generatedCount += 1
        }
    }

    private func generateTitle(for context: SessionTitleContext) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }

        do {
            return try await FoundationModelSessionTitleGenerator.generateTitle(for: context)
        } catch FoundationModelSessionTitleGeneratorError.modelUnavailable {
            disabledUntil = Date().addingTimeInterval(10 * 60)
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

enum SessionTitleHeuristics {
    static func apply(to sessions: [AgentSession]) -> [AgentSession] {
        sessions.map { session in
            var copy = session
            copy.title = title(for: SessionTitleContext(session: copy))
            return copy
        }
    }

    static func title(for context: SessionTitleContext) -> String {
        if let title = SessionTitleText.displayTitle(from: context.rawTitle, context: context) {
            return title
        }

        if let title = SessionTitleText.displayTitle(from: context.preview, context: context) {
            return title
        }

        switch context.harness {
        case .terminal:
            return context.projectName.isEmpty ? "Shell" : "Shell - \(context.projectName)"
        case .codex:
            return "Codex Session"
        case .claude:
            return "Claude Session"
        case .pi:
            return "Pi Session"
        }
    }
}

struct SessionTitleContext: Sendable {
    var sessionID: String
    var rawTitle: String
    var preview: String
    var projectName: String
    var cwd: String
    var harness: HarnessID
    var status: SessionStatusKind
    var terminalName: String?

    init(session: AgentSession) {
        sessionID = session.id
        rawTitle = session.title
        preview = session.preview
        projectName = session.projectName
        cwd = session.cwd
        harness = session.harness
        status = session.status
        terminalName = session.terminalName
    }

    var signature: String {
        [
            sessionID,
            rawTitle,
            preview,
            projectName,
            cwd,
            harness.rawValue,
            status.rawValue
        ].joined(separator: "||")
    }

    var modelSeed: String {
        [
            rawTitle,
            preview
        ]
        .compactMap { value in
            let cleaned = SessionTitleText.clean(value)
            return cleaned.isEmpty ? nil : cleaned
        }
        .joined(separator: "\n")
    }

    var hasUsefulModelInput: Bool {
        let seed = modelSeed
        guard seed.count >= 8 else { return false }
        return !SessionTitleText.isGeneric(seed, harness: harness)
    }

    var prompt: String {
        """
        Project: \(projectName)
        Working directory: \(cwd)
        Harness: \(harness.displayName)
        Terminal: \(terminalName ?? "Unknown")
        Status: \(status.title)
        Current title: \(SessionTitleText.truncated(rawTitle, limit: 180))
        Recent context: \(SessionTitleText.truncated(preview, limit: 300))
        """
    }
}

enum SessionTitleText {
    static func displayTitle(from value: String, context: SessionTitleContext) -> String? {
        let cleaned = clean(value)
        guard !cleaned.isEmpty,
              !isGeneric(cleaned, harness: context.harness),
              !looksLikeProcessLabel(cleaned),
              !looksLikeTranscriptFilename(cleaned),
              !looksLikeModelOrUsageLabel(cleaned),
              !looksLikePath(cleaned) else {
            return nil
        }

        guard let phrase = firstUsefulPhrase(in: cleaned) else { return nil }
        let stripped = stripLeadingFiller(from: phrase)
        let words = stripped
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }
        let limited = words.prefix(6).joined(separator: " ")
        return titleCase(limited)
    }

    static func cleanGeneratedTitle(_ value: String, fallbackContext context: SessionTitleContext) -> String? {
        let cleaned = clean(value)
        guard !cleaned.isEmpty else { return nil }

        let title = cleaned
            .replacingOccurrences(of: #"(?i)^title:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:;- "))

        guard !title.isEmpty,
              title.count <= 48,
              title.split(separator: " ").count <= 7,
              !isGeneric(title, harness: context.harness),
              !looksLikeProcessLabel(title),
              !looksLikeTranscriptFilename(title),
              !looksLikeModelOrUsageLabel(title),
              !looksLikePath(title) else {
            return nil
        }

        return titleCase(title)
    }

    static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncated(_ value: String, limit: Int) -> String {
        let cleaned = clean(value)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit))
    }

    static func isGeneric(_ value: String, harness: HarnessID) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let genericValues: Set<String> = [
            "",
            "bash",
            "claude",
            "claude code",
            "codex",
            "codex app",
            "codex session",
            "fish",
            "ghostty",
            "openai codex",
            "pi",
            "pi session",
            "shell",
            "sh",
            "terminal",
            "zsh"
        ]

        if genericValues.contains(normalized) {
            return true
        }

        switch harness {
        case .codex:
            return normalized == HarnessID.codex.displayName.lowercased()
        case .claude:
            return normalized == HarnessID.claude.displayName.lowercased()
        case .pi:
            return normalized == HarnessID.pi.displayName.lowercased()
        case .terminal:
            return false
        }
    }

    private static func firstUsefulPhrase(in value: String) -> String? {
        let separators = CharacterSet(charactersIn: "\n.?!")
        let parts = value.components(separatedBy: separators)
        let phrase = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return phrase?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
    }

    private static func stripLeadingFiller(from value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = result.lowercased()
        let prefixes = [
            "can we ",
            "can you ",
            "could we ",
            "could you ",
            "would you ",
            "please ",
            "okay ",
            "ok ",
            "let's ",
            "lets ",
            "i need to ",
            "we need to "
        ]

        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }

        return result
    }

    private static func titleCase(_ value: String) -> String {
        let acronyms: [String: String] = [
            "ai": "AI",
            "api": "API",
            "cli": "CLI",
            "json": "JSON",
            "jsonl": "JSONL",
            "macos": "macOS",
            "pr": "PR",
            "spm": "SPM",
            "ui": "UI",
            "url": "URL",
            "xcode": "Xcode"
        ]
        let minorWords: Set<String> = ["a", "an", "and", "as", "at", "for", "in", "of", "on", "or", "the", "to", "with"]
        let words = value.split(separator: " ").map(String.init)

        return words.enumerated().map { index, word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?()[]{}"))
            let key = trimmed.lowercased()
            if let acronym = acronyms[key] { return acronym }
            if index > 0, minorWords.contains(key) { return key }
            guard let first = trimmed.first else { return trimmed }
            return first.uppercased() + trimmed.dropFirst()
        }.joined(separator: " ")
    }

    private static func looksLikeProcessLabel(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("pid ") { return true }
        if lowercased.contains(" pid ") { return true }
        return lowercased == "codex app is running"
    }

    private static func looksLikeTranscriptFilename(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("rollout-")
            || lowercased.hasSuffix(".jsonl")
    }

    private static func looksLikeModelOrUsageLabel(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let modelPrefixes = ["claude-", "gpt-", "o3", "o4", "gemini-", "llama-", "mistral-"]
        if modelPrefixes.contains(where: lowercased.hasPrefix) { return true }
        return lowercased.contains(" tokens")
            || lowercased.contains(" tools")
            || lowercased.contains(" · ")
            || lowercased.contains(" cost")
    }

    private static func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~/") || value.contains("/Users/")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum FoundationModelSessionTitleGeneratorError: Error {
    case modelUnavailable
}

@available(macOS 26.0, *)
private enum FoundationModelSessionTitleGenerator {
    static func generateTitle(for context: SessionTitleContext) async throws -> String? {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard model.isAvailable else {
            throw FoundationModelSessionTitleGeneratorError.modelUnavailable
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You name local coding terminal sessions.
            Return only a short title, 2 to 5 words.
            Prefer a concrete verb phrase like "Fix Session Titles".
            Do not include app names, project names, quotes, punctuation, or explanations.
            """
        )

        let response = try await session.respond(
            to: context.prompt,
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 16)
        )

        return SessionTitleText.cleanGeneratedTitle(response.content, fallbackContext: context)
    }
}
#endif
