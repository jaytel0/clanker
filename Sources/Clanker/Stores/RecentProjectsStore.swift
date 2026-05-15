import Combine
import Foundation

/// Owns the live list of recent projects shown in the notch.
///
/// Two inputs: filesystem scans (timer + manual) and the active sessions
/// list (so we can flag and float repos with running agents). Outputs one
/// `@Published` `recents` array already sorted by recency for direct
/// display — no cap, the notch is scrollable.
@MainActor
final class RecentProjectsStore: ObservableObject {
    @Published private(set) var recents: [RecentProject] = []

    private let settings: RecentsSettings
    private let sessionStore: LocalSessionStore
    private var rawRecents: [RecentProject] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init(settings: RecentsSettings = .shared, sessionStore: LocalSessionStore) {
        self.settings = settings
        self.sessionStore = sessionStore

        // Re-derive whenever inputs change. The actual filesystem scan runs
        // on its own timer; everything else is cheap reshape work.
        sessionStore.$sessions
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshDerived()
            }
            .store(in: &cancellables)

        settings.$roots
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scan()
            }
            .store(in: &cancellables)
    }

    func start() {
        guard timer == nil else { return }
        scan()
        // 60s feels like the right cadence: cheap enough not to matter, fresh
        // enough that "I just committed" rerankings feel near-immediate when
        // the user next opens the notch.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force a rescan now — used when the notch expands so the list is fresh
    /// at the exact moment the user is about to look at it.
    func refreshOnDemand() {
        scan()
    }

    // MARK: - Pipeline

    private func scan() {
        let roots = settings.roots
        Task.detached(priority: .utility) {
            let scanned = RecentProjectScanner.scan(roots: roots)
            await MainActor.run {
                self.rawRecents = scanned
                self.refreshDerived()
            }
        }
    }

    /// Take the latest scan + the latest sessions and produce the list shown
    /// in the UI. Pure function over `rawRecents` and `sessionStore.sessions`.
    private func refreshDerived() {
        let activePaths = activeSessionPaths(from: sessionStore.sessions)
        let now = Date()

        let merged: [RecentProject] = rawRecents.map { project in
            var copy = project
            if hasActiveSession(in: activePaths, repoPath: project.path) {
                copy.hasActiveSession = true
                // Float "actively-being-worked-on" repos to the top regardless
                // of git mtime — matches user intent: this is what you're
                // doing right now.
                if copy.score < now.addingTimeInterval(-30) {
                    return RecentProject(
                        path: copy.path,
                        name: copy.name,
                        category: copy.category,
                        score: now,
                        githubURL: copy.githubURL,
                        hasActiveSession: true
                    )
                }
            }
            return copy
        }

        let sorted = merged.sorted { $0.score > $1.score }
        if sorted != recents {
            recents = sorted
        }
    }

    /// Normalize the live sessions' cwds into a set we can efficiently test
    /// `hasPrefix` against per repo.
    private func activeSessionPaths(from sessions: [AgentSession]) -> [String] {
        sessions
            .filter(\.countsAsLiveActive)
            .map { expandHome($0.cwd) }
    }

    private func hasActiveSession(in activePaths: [String], repoPath: String) -> Bool {
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        for path in activePaths {
            if path == repoPath || path.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    private func expandHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }
}
