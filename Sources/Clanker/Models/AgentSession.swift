import Foundation

enum HarnessID: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case pi
    case terminal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "OpenAI Codex"
        case .claude: "Claude"
        case .pi: "Pi"
        case .terminal: "Terminal"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "circle.hexagongrid.fill"
        case .claude: "sparkle.magnifyingglass"
        case .pi: "pi"
        case .terminal: "apple.terminal.fill"
        }
    }
}

enum SessionStatusKind: String, Sendable {
    /// The harness/shell exists but isn't actively producing output. Display
    /// label is "Idle" — the historical "Active" name was misleading because
    /// every live row was "active" by virtue of existing.
    case active
    case thinking
    case runningTool
    /// Agent is currently producing output (transcript bytes flowing). Set
    /// either by transcript parsers that see in-flight events or promoted
    /// at the view layer when `lastActivity` is recent. See
    /// `StatusPill.effectiveStatus`.
    case working
    case waitingForApproval
    case waitingForInput
    case completed
    case idle
    case error

    var title: String {
        switch self {
        case .active: "Idle"
        case .thinking: "Thinking"
        case .runningTool: "Running tool"
        case .working: "Working\u{2026}"
        case .waitingForApproval: "Needs approval"
        case .waitingForInput: "Needs input"
        case .completed: "Complete"
        case .idle: "Idle"
        case .error: "Error"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .error:
            true
        case .active, .thinking, .runningTool, .working, .completed, .idle:
            false
        }
    }
}

enum SessionCloseCapability: String, Sendable {
    case none
    case terminalSession
    case processGroup

    var canClose: Bool {
        self != .none
    }

    var requiresConfirmation: Bool {
        self == .processGroup
    }

    var helpTitle: String {
        switch self {
        case .none: "Session cannot be closed from Clanker"
        case .terminalSession: "Close terminal session"
        case .processGroup: "Terminate process group"
        }
    }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var projectName: String
    var cwd: String
    var harness: HarnessID
    var status: SessionStatusKind
    var preview: String
    var lastActivity: Date
    var pid: Int?
    var terminalName: String?
    /// Path to the controlling tty for the shell, e.g. `/dev/ttys004`. Used by
    /// `TerminalFocusService` to find the matching window/tab.
    var tty: String?
    /// True when this row is backed by a currently running process, terminal,
    /// or live app connection. Transcript-only history can still appear in the
    /// expanded list, but it must not inflate live terminal/session counts.
    var isLive: Bool
    /// Bundle to activate for sessions that are not backed by a terminal tab
    /// or whose host app is easier to resolve by bundle id.
    var appBundleID: String?
    /// Deep link to the owning app/session when the provider exposes one.
    var launchURL: String?
    /// Whether Clanker can safely offer a close control for this row.
    var closeCapability: SessionCloseCapability = .none

    var needsAttention: Bool {
        status.needsAttention
    }

    var countsAsLiveActive: Bool {
        isLive && status != .idle && status != .active && status != .completed
    }
}
