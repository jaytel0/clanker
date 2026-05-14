import Combine
import Foundation

@MainActor
final class MockSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = [
        AgentSession(
            id: UUID(),
            title: "Refactor hook bridge",
            projectName: "farm",
            cwd: "~/Developer/personal/farm",
            harness: .codex,
            status: .waitingForApproval,
            preview: "Bash wants to run swift test",
            lastActivity: Date().addingTimeInterval(-45)
        ),
        AgentSession(
            id: UUID(),
            title: "Landing cleanup",
            projectName: "site",
            cwd: "~/Developer/personal/site",
            harness: .claude,
            status: .thinking,
            preview: "Reviewing component layout",
            lastActivity: Date().addingTimeInterval(-190)
        ),
        AgentSession(
            id: UUID(),
            title: "Pi cost review",
            projectName: "farm",
            cwd: "~/Developer/personal/farm",
            harness: .pi,
            status: .completed,
            preview: "$1.42 today across 4 sessions",
            lastActivity: Date().addingTimeInterval(-360)
        ),
        AgentSession(
            id: UUID(),
            title: "zsh",
            projectName: "world",
            cwd: "~/world",
            harness: .terminal,
            status: .idle,
            preview: "Plain terminal session",
            lastActivity: Date().addingTimeInterval(-900)
        )
    ]

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rotateMockState()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rotateMockState() {
        guard !sessions.isEmpty else { return }
        sessions[0].lastActivity = Date()
        sessions[1].status = sessions[1].status == .thinking ? .waitingForInput : .thinking
        sessions[1].lastActivity = Date().addingTimeInterval(-20)
    }
}
