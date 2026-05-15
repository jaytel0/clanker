import Combine
import Foundation

@MainActor
final class LocalSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
