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
            harness.rawValue
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
    private static let maxTitleWords = 10
    private static let maxGeneratedTitleCharacters = 80

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
        guard let taskPhrase = taskPhrase(from: phrase, context: context) else { return nil }
        let words = taskPhrase
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }
        let limited = words.prefix(maxTitleWords).joined(separator: " ")
        return phraseCase(limited)
    }

    static func cleanGeneratedTitle(_ value: String, fallbackContext context: SessionTitleContext) -> String? {
        let cleaned = clean(value)
        guard !cleaned.isEmpty else { return nil }

        let title = cleaned
            .replacingOccurrences(of: #"(?i)^title:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:;- "))

        guard !title.isEmpty,
              title.count <= maxGeneratedTitleCharacters,
              title.split(separator: " ").count <= maxTitleWords,
              !isGeneric(title, harness: context.harness),
              !looksLikeProcessLabel(title),
              !looksLikeTranscriptFilename(title),
              !looksLikeModelOrUsageLabel(title),
              !looksLikePath(title) else {
            return nil
        }

        let taskTitle = taskPhrase(from: title, context: context) ?? title
        return phraseCase(taskTitle)
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

    private static func taskPhrase(from value: String, context: SessionTitleContext) -> String? {
        let stripped = stripLeadingFiller(from: value)
        let normalized = normalizeUserRequest(stripped)
        guard !normalized.isEmpty,
              !isGeneric(normalized, harness: context.harness),
              !looksLikeModelOrUsageLabel(normalized),
              !looksLikePath(normalized) else {
            return nil
        }
        return normalized
    }

    private static func stripLeadingFiller(from value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var lowercased = result.lowercased()
        let prefixes = [
            "can we ",
            "can you ",
            "could we ",
            "could you ",
            "would you ",
            "please ",
            "okay ",
            "ok ",
            "i want to ",
            "i'd like to ",
            "let's ",
            "lets ",
            "i need to ",
            "i need you to ",
            "we should ",
            "we need to "
        ]

        var stripped = true
        while stripped {
            stripped = false
            for prefix in prefixes where lowercased.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                lowercased = result.lowercased()
                stripped = true
                break
            }
        }

        return result
    }

    private static func normalizeUserRequest(_ value: String) -> String {
        let value = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:;-?! "))
        let lowercased = value.lowercased()

        if let subject = subject(afterAnyPrefix: [
            "make the ",
            "make a ",
            "make an ",
            "make "
        ], in: lowercased, original: value),
           let improvedSubject = stripTrailingQualityWord(from: subject) {
            return "Improve \(stripLeadingArticle(from: improvedSubject))"
        }

        if let subject = subject(afterAnyPrefix: [
            "improve the ",
            "improve a ",
            "improve an ",
            "improve "
        ], in: lowercased, original: value) {
            return "Improve \(stripLeadingArticle(from: subject))"
        }

        if let subject = subject(afterAnyPrefix: [
            "fix the ",
            "fix a ",
            "fix an ",
            "fix "
        ], in: lowercased, original: value) {
            return "Fix \(stripLeadingArticle(from: subject))"
        }

        if let subject = missingInstallSubject(from: lowercased, original: value) {
            return "Handle missing \(subject) install"
        }

        if let subject = clickBehaviorSubject(from: lowercased, original: value) {
            return "Fix \(subject) click behavior"
        }

        if let subject = workingStatusSubject(from: lowercased, original: value) {
            return "Check \(stripLeadingArticle(from: subject)) status"
        }

        if let subject = howWorksSubject(from: lowercased, original: value) {
            if subject == "current" {
                return "Inspect current behavior"
            }
            return "Inspect \(stripLeadingArticle(from: subject)) behavior"
        }

        return value
    }

    private static func subject(afterAnyPrefix prefixes: [String], in lowercased: String, original: String) -> String? {
        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let start = original.index(original.startIndex, offsetBy: prefix.count)
            let subject = String(original[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return subject.isEmpty ? nil : subject
        }
        return nil
    }

    private static func stripTrailingQualityWord(from value: String) -> String? {
        let endings = [
            " better",
            " nicer",
            " cleaner",
            " clearer",
            " good",
            " great"
        ]
        let lowercased = value.lowercased()
        for ending in endings where lowercased.hasSuffix(ending) {
            let end = value.index(value.endIndex, offsetBy: -ending.count)
            let subject = String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return subject.isEmpty ? nil : subject
        }
        return nil
    }

    private static func stripLeadingArticle(from value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = result.lowercased()
        for article in ["the ", "a ", "an "] where lowercased.hasPrefix(article) {
            result = String(result.dropFirst(article.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return result
    }

    private static func missingInstallSubject(from lowercased: String, original: String) -> String? {
        let installPhrases = [
            " doesn't have ",
            " doesnt have ",
            " does not have ",
            " missing "
        ]
        guard lowercased.hasPrefix("if ") || lowercased.hasPrefix("when ") else { return nil }

        for phrase in installPhrases {
            guard let range = lowercased.range(of: phrase) else { continue }
            let startOffset = lowercased.distance(from: lowercased.startIndex, to: range.upperBound)
            let start = original.index(original.startIndex, offsetBy: startOffset)
            var subject = String(original[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" installed", " install"] where subject.lowercased().hasSuffix(suffix) {
                let end = subject.index(subject.endIndex, offsetBy: -suffix.count)
                subject = String(subject[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let stripped = stripLeadingArticle(from: subject)
            return stripped.isEmpty ? nil : stripped
        }

        return nil
    }

    private static func clickBehaviorSubject(from lowercased: String, original: String) -> String? {
        guard lowercased.hasPrefix("when ") || lowercased.hasPrefix("click ") else { return nil }
        let clickPhrases = [
            "click on a ",
            "click on an ",
            "click on the ",
            "click on ",
            "click a ",
            "click an ",
            "click the ",
            "click "
        ]

        for phrase in clickPhrases {
            guard let range = lowercased.range(of: phrase) else { continue }
            let startOffset = lowercased.distance(from: lowercased.startIndex, to: range.upperBound)
            let start = original.index(original.startIndex, offsetBy: startOffset)
            let subject = String(original[start...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".:;-?! "))
            let stripped = stripLeadingArticle(from: subject)
            return stripped.isEmpty ? nil : stripped
        }

        return nil
    }

    private static func workingStatusSubject(from lowercased: String, original: String) -> String? {
        guard lowercased.hasPrefix("is ") || lowercased.hasPrefix("are ") else { return nil }
        let prefixes = ["is our ", "is the ", "is a ", "is an ", "is ", "are our ", "are the ", "are "]
        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let start = original.index(original.startIndex, offsetBy: prefix.count)
            let remainder = String(original[start...])
            let remainderLowercased = remainder.lowercased()
            for suffix in [" working", " broken", " fixed", " ready"] where remainderLowercased.hasSuffix(suffix) {
                let end = remainder.index(remainder.endIndex, offsetBy: -suffix.count)
                let subject = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                return subject.isEmpty ? nil : subject
            }
        }
        return nil
    }

    private static func howWorksSubject(from lowercased: String, original: String) -> String? {
        let prefixes = ["how does ", "how is ", "how's ", "hows "]
        let suffixes = [" work now", " working now", " work", " working"]

        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let start = original.index(original.startIndex, offsetBy: prefix.count)
            var subject = String(original[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let subjectLowercased = subject.lowercased()
            for suffix in suffixes where subjectLowercased.hasSuffix(suffix) {
                let end = subject.index(subject.endIndex, offsetBy: -suffix.count)
                subject = String(subject[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }

            let stripped = stripLeadingArticle(from: subject)
            guard !stripped.isEmpty else { return nil }
            if ["it", "this", "that"].contains(stripped.lowercased()) {
                return "current"
            }
            return stripped
        }

        return nil
    }

    private static func phraseCase(_ value: String) -> String {
        let preservedWords: [String: String] = [
            "ai": "AI",
            "appkit": "AppKit",
            "api": "API",
            "claude": "Claude",
            "codex": "Codex",
            "gcp": "GCP",
            "git": "Git",
            "ghostty": "Ghostty",
            "github": "GitHub",
            "graphql": "GraphQL",
            "ios": "iOS",
            "javascript": "JavaScript",
            "cli": "CLI",
            "json": "JSON",
            "jsonl": "JSONL",
            "macos": "macOS",
            "openai": "OpenAI",
            "pi": "Pi",
            "pr": "PR",
            "readme": "README",
            "spm": "SPM",
            "swift": "Swift",
            "swiftpm": "SwiftPM",
            "swiftui": "SwiftUI",
            "typescript": "TypeScript",
            "ui": "UI",
            "url": "URL",
            "xcode": "Xcode"
        ]
        let words = value.split(separator: " ").map(String.init)

        return words.enumerated().map { index, word in
            phraseCaseWord(word, isFirst: index == 0, preservedWords: preservedWords)
        }.joined(separator: " ")
    }

    private static func phraseCaseWord(
        _ value: String,
        isFirst: Bool,
        preservedWords: [String: String]
    ) -> String {
        let trimSet = CharacterSet(charactersIn: "\"'`.,:;!?()[]{}")
        let prefix = String(value.prefix { character in
            String(character).rangeOfCharacter(from: trimSet) != nil
        })
        let suffix = String(value.reversed().prefix { character in
            String(character).rangeOfCharacter(from: trimSet) != nil
        }.reversed())
        let coreStart = value.index(value.startIndex, offsetBy: prefix.count)
        let coreEnd = value.index(value.endIndex, offsetBy: -suffix.count)
        guard coreStart <= coreEnd else { return value }

        let core = String(value[coreStart..<coreEnd])
        guard !core.isEmpty else { return value }

        let key = core.lowercased()
        if let preserved = preservedWords[key] {
            return prefix + preserved + suffix
        }

        let lowercased = core.lowercased()
        if isFirst, let first = lowercased.first {
            return prefix + first.uppercased() + String(lowercased.dropFirst()) + suffix
        }

        return prefix + lowercased + suffix
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
            You name local coding sessions by the active engineering task.
            Return only a concise sentence-case title, 10 words or fewer.
            Do not mirror the user's question or write from the user's perspective.
            Prefer imperative task phrases like "Fix session titles" or "Improve model naming".
            Examples:
            "Can we make the foundation model naming better?" -> "Improve foundation model naming"
            "When I click on a session..." -> "Fix session click behavior"
            "Is our foundation model working?" -> "Check foundation model status"
            Do not include app names, project names, quotes, punctuation, or explanations.
            """
        )

        let response = try await session.respond(
            to: context.prompt,
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 32)
        )

        return SessionTitleText.cleanGeneratedTitle(response.content, fallbackContext: context)
    }
}
#endif
