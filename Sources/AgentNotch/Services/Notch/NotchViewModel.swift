import Combine
import Foundation

enum SessionGroupingMode: String, CaseIterable, Identifiable {
    case attention = "Attention"
    case project = "Project"
    case harness = "Harness"

    var id: String { rawValue }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var groupingMode: SessionGroupingMode = .attention
    @Published private(set) var sessions: [AgentSession] = []

    private var cancellables = Set<AnyCancellable>()

    init(sessionStore: MockSessionStore) {
        sessionStore.$sessions
            .sink { [weak self] sessions in
                self?.sessions = sessions.sortedForNotch()
            }
            .store(in: &cancellables)
    }

    var activeCount: Int {
        sessions.filter { $0.status != .idle }.count
    }

    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    var representativeSession: AgentSession? {
        sessions.first
    }

    var groupedSessions: [(title: String, sessions: [AgentSession])] {
        switch groupingMode {
        case .attention:
            let attention = sessions.filter(\.needsAttention)
            return [(attention.isEmpty ? "No Attention Needed" : "Needs Attention", attention.isEmpty ? sessions : attention)]
        case .project:
            return Dictionary(grouping: sessions, by: \.projectName)
                .map { ($0.key, $0.value.sortedForNotch()) }
                .sorted { lhs, rhs in
                    lhs.sessions.first?.lastActivity ?? .distantPast > rhs.sessions.first?.lastActivity ?? .distantPast
                }
        case .harness:
            return Dictionary(grouping: sessions, by: { $0.harness.displayName })
                .map { ($0.key, $0.value.sortedForNotch()) }
                .sorted { $0.title < $1.title }
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }
}

private extension Array where Element == AgentSession {
    func sortedForNotch() -> [AgentSession] {
        sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            if lhs.status == .completed && rhs.status != .completed {
                return true
            }
            if lhs.status != .completed && rhs.status == .completed {
                return false
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }
}
