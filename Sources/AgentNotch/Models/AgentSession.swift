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
    case active
    case thinking
    case runningTool
    case waitingForApproval
    case waitingForInput
    case completed
    case idle
    case error

    var title: String {
        switch self {
        case .active: "Active"
        case .thinking: "Thinking"
        case .runningTool: "Running tool"
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
        case .active, .thinking, .runningTool, .completed, .idle:
            false
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

    var needsAttention: Bool {
        status.needsAttention
    }
}
