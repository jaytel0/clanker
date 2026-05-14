import Combine
import Foundation
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isHovering = false
    @Published private(set) var sessions: [AgentSession] = []

    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?

    init(sessionStore: LocalSessionStore) {
        sessionStore.$sessions
            .removeDuplicates()
            .sink { [weak self] sessions in
                self?.sessions = sessions.sortedForNotch()
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    var activeCount: Int {
        sessions.filter { $0.status != .idle && $0.status != .completed }.count
    }

    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    var representativeSession: AgentSession? {
        sessions.first(where: \.needsAttention) ?? sessions.first
    }

    /// Up to three harness icons to fan out in the closed bar.
    var representativeHarnesses: [HarnessID] {
        var seen: [HarnessID] = []
        for session in sessions {
            if !seen.contains(session.harness) {
                seen.append(session.harness)
            }
            if seen.count == 3 { break }
        }
        return seen
    }

    var groupedSessions: [SessionGroup] {
        Dictionary(grouping: sessions, by: \.projectName)
            .map { SessionGroup(title: $0.key, sessions: $0.value.sortedForNotch()) }
            .sorted { lhs, rhs in
                let lhsAttention = lhs.sessions.contains(where: \.needsAttention)
                let rhsAttention = rhs.sessions.contains(where: \.needsAttention)
                if lhsAttention != rhsAttention { return lhsAttention }
                let lhsActivity = lhs.sessions.first?.lastActivity ?? .distantPast
                let rhsActivity = rhs.sessions.first?.lastActivity ?? .distantPast
                return lhsActivity > rhsActivity
            }
    }

    // MARK: - Intent

    func toggleExpanded() {
        cancelHoverTasks()
        withAnimation(NotchMotion.morph) {
            isExpanded.toggle()
        }
    }

    func collapse() {
        cancelHoverTasks()
        guard isExpanded else { return }
        withAnimation(NotchMotion.morph) {
            isExpanded = false
        }
    }

    /// Activates the terminal that owns the session and dismisses the notch.
    func activate(_ session: AgentSession) {
        TerminalFocusService.focus(session)
        collapse()
    }

    func setHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering

        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            scheduleHoverOpen()
        } else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            scheduleHoverClose()
        }
    }

    // MARK: - Hover scheduling

    private func scheduleHoverOpen() {
        guard !isExpanded else { return }
        hoverOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms — feels instant but filters cursor flick-past
            guard !Task.isCancelled, let self, self.isHovering, !self.isExpanded else { return }
            await MainActor.run {
                withAnimation(NotchMotion.morph) {
                    self.isExpanded = true
                }
            }
        }
    }

    private func scheduleHoverClose() {
        guard isExpanded else { return }
        hoverCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms — tight grace period so quick re-entry doesn't collapse
            guard !Task.isCancelled, let self, !self.isHovering, self.isExpanded else { return }
            await MainActor.run {
                withAnimation(NotchMotion.morph) {
                    self.isExpanded = false
                }
            }
        }
    }

    private func cancelHoverTasks() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask = nil
    }
}

struct SessionGroup: Identifiable {
    var title: String
    var sessions: [AgentSession]
    var id: String { title }
}

extension Array where Element == AgentSession {
    func sortedForNotch() -> [AgentSession] {
        sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            let lhsActive = lhs.status == .active || lhs.status == .thinking || lhs.status == .runningTool
            let rhsActive = rhs.status == .active || rhs.status == .thinking || rhs.status == .runningTool
            if lhsActive != rhsActive {
                return lhsActive
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }
}

/// Shared motion vocabulary so every transition feels related.
enum NotchMotion {
    /// Container morph — slightly snappy, very low overshoot. Tuned to match
    /// the system Dynamic Island feel.
    static let morph: Animation = .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)

    /// Content fade/slide once the morph has settled.
    static let content: Animation = .spring(response: 0.34, dampingFraction: 0.92, blendDuration: 0)

    /// Row insert/remove — a touch springier so list shifts feel alive.
    static let row: Animation = .spring(response: 0.45, dampingFraction: 0.82, blendDuration: 0)

    /// Hover micro-scale; very fast.
    static let hover: Animation = .spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0)
}
