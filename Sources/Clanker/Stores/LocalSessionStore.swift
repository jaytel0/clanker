import Combine
import Foundation

@MainActor
final class LocalSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        // 2s tick — fresh enough that the StatusPill's "Working\u{2026}"
        // promotion (a 4s window keyed off transcript mtime) reliably picks
        // up new bursts of agent activity. The full scan is dominated by a
        // few cheap `ps` / `lsof` calls, so 2s is well under the budget.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Task {
            await CodexAppServerSource.shared.stop()
        }
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let sessions = await LocalSessionScanner.scan()
            await MainActor.run {
                self.sessions = sessions
            }
        }
    }
}
