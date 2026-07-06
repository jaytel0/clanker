import Foundation

// MARK: - Normalized Discovery Model

/// Trust level of a discovery source when merging duplicate observations.
/// Higher values win field-by-field conflicts.
enum DiscoverySourceKind: Int, Sendable {
    case appServer = 90
    case transcript = 70
    case process = 50
    case app = 30
}

struct DiscoveredSession: Sendable {
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
    var terminalContext: TerminalContext
    var appBundleID: String?
    var launchURL: String?

    init(
        sessionKey: String?,
        sourceKind: DiscoverySourceKind,
        id: String,
        title: String,
        cwd: String,
        harness: HarnessID,
        status: SessionStatusKind,
        preview: String,
        lastActivity: Date,
        pid: Int?,
        terminalName: String?,
        tty: String?,
        terminalContext: TerminalContext = .empty,
        appBundleID: String?,
        launchURL: String?
    ) {
        self.sessionKey = sessionKey
        self.sourceKind = sourceKind
        self.id = id
        self.title = title
        self.cwd = cwd
        self.harness = harness
        self.status = status
        self.preview = preview
        self.lastActivity = lastActivity
        self.pid = pid
        self.terminalName = terminalName
        self.tty = tty
        self.appBundleID = appBundleID
        self.launchURL = launchURL

        let legacyContext = TerminalContext(
            terminalBundleID: Self.legacyTerminalBundleID(
                appBundleID: appBundleID,
                terminalName: terminalName,
                tty: tty
            ),
            terminalProgram: terminalName,
            terminalSessionID: nil,
            iTermSessionID: nil,
            tty: tty,
            tmuxSession: nil,
            tmuxPane: nil,
            cwd: cwd,
            source: Self.terminalContextSource(for: sourceKind),
            confidence: Self.terminalContextConfidence(for: sourceKind, tty: tty, terminalName: terminalName)
        )
        self.terminalContext = terminalContext.isEmpty
            ? legacyContext
            : legacyContext.merged(with: terminalContext)
    }

    var normalizedCWD: String {
        DiscoveryHelpers.normalizedPath(cwd)
    }

    var isTerminalBacked: Bool {
        terminalName?.isEmpty == false || tty?.isEmpty == false || terminalContext.hasTerminalBacking
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
            terminalContext: terminalContext,
            closeCapability: closeCapability
        )
    }

    private static func terminalContextSource(for sourceKind: DiscoverySourceKind) -> TerminalContextSource {
        switch sourceKind {
        case .appServer: return .appServer
        case .transcript: return .transcript
        case .process: return .process
        case .app: return .app
        }
    }

    private static func terminalContextConfidence(
        for sourceKind: DiscoverySourceKind,
        tty: String?,
        terminalName: String?
    ) -> TerminalContextConfidence {
        if tty?.isEmpty == false {
            return sourceKind == .process ? .medium : .high
        }
        if terminalName?.isEmpty == false {
            return .low
        }
        return .unknown
    }

    private static func legacyTerminalBundleID(
        appBundleID: String?,
        terminalName: String?,
        tty: String?
    ) -> String? {
        guard let appBundleID else { return nil }
        if terminalName?.isEmpty == false || tty?.isEmpty == false {
            return appBundleID
        }
        return TerminalApp.app(withBundleID: appBundleID) == nil ? nil : appBundleID
    }
}

// MARK: - Merging

enum SessionMerger {
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

        if let identityKey = candidate.terminalContext.stableIdentityKey {
            if let index = sessions.firstIndex(where: {
                $0.harness == candidate.harness
                    && $0.terminalContext.stableIdentityKey == identityKey
            }) {
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
            guard isContextualMergeFresh(existing, candidate) else { return false }
            return true
        }

        // CWD-only correlation is a last resort. If there are multiple same
        // project candidates, keeping separate rows is better than attaching a
        // fresh transcript to the wrong terminal.
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func isContextualMergeFresh(_ lhs: DiscoveredSession, _ rhs: DiscoveredSession) -> Bool {
        guard lhs.sourceKind == .transcript || rhs.sourceKind == .transcript else {
            return false
        }

        let transcript = lhs.sourceKind == .transcript ? lhs : rhs
        let age = Date().timeIntervalSince(transcript.lastActivity)
        switch transcript.status {
        case .waitingForApproval, .waitingForInput:
            // Prompts legitimately sit unanswered for a long time.
            return age < 2 * 60 * 60
        case .error, .working, .runningTool, .thinking, .active:
            return age < 15 * 60
        case .idle, .completed:
            return false
        }
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
            terminalContext: preferred.terminalContext.merged(with: other.terminalContext),
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

    static func mostImportantStatus(_ lhs: SessionStatusKind, _ rhs: SessionStatusKind) -> SessionStatusKind {
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

        // A source's placeholder title ("Codex", "Claude Code", …) always
        // loses to anything more specific from the other source.
        if harness != .terminal,
           trimmed == harness.defaultSessionTitle,
           fallback != harness.defaultSessionTitle {
            return fallback
        }
        return trimmed
    }

    private static func richerPreview(_ preview: String, fallback: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("PID ") {
            return trimmed
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? trimmed
    }
}
