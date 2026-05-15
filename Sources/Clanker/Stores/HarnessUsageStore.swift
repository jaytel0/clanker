import Combine
import Foundation

@MainActor
final class HarnessUsageStore: ObservableObject {
    @Published private(set) var snapshots: [HarnessUsageSnapshot] = []

    private var timer: Timer?
    private var isRefreshing = false
    private let configuration: HarnessUsageScanConfiguration

    init(configuration: HarnessUsageScanConfiguration = .default) {
        self.configuration = configuration
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refreshNow() {
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let configuration = configuration
        Task.detached(priority: .utility) {
            let snapshots = HarnessUsageScanner.scan(configuration: configuration)
            await MainActor.run {
                self.snapshots = snapshots
                self.isRefreshing = false
            }
        }
    }
}
