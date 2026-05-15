import Combine
import Foundation

@MainActor
final class LocalSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?
    private var isRefreshing = false

    func start() {
        guard timer == nil else { return }
        refresh()
        // 1s tick — keeps the list feeling live. The scan is just a few
        // cheap `ps` / stat calls, well under budget at this rate.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Force an immediate refresh (e.g. after closing a session).
    func refreshNow() {
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Task {
            await CodexAppServerSource.shared.stop()
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) {
            let sessions = await LocalSessionScanner.scan()
            let titledSessions = await SessionTitleService.shared.applyCachedTitles(to: sessions)
            await MainActor.run {
                self.sessions = titledSessions
                self.isRefreshing = false
            }

            Task.detached(priority: .utility) {
                await SessionTitleService.shared.generateMissingTitles(for: sessions)
            }
        }
    }
}
