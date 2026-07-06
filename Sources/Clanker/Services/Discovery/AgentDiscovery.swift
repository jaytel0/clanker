import Foundation

/// Orchestrates one discovery pass across every source and merges the
/// results into UI-ready sessions.
///
/// Source layers, in merge-priority order:
///   * `CodexAppServerSource` — live thread list from a Codex app-server.
///   * transcript sources — Codex / Claude / Pi session files on disk.
///   * `TerminalProcessSource` — the process table: every tty with a shell
///     or harness, plus tty-less harness processes.
///   * `MacAppSource` — running agent apps with no finer-grained signal.
///
/// The process scan runs every tick (it's one `ps` plus syscalls); transcript
/// parsing is gated behind `TranscriptSessionCache` and per-file mtime caches
/// so steady-state ticks only stat files.
enum LocalSessionScanner {
    private static let transcriptRefreshInterval: TimeInterval = 8

    static func scan() async -> [AgentSession] {
        let processSnapshot = ProcessSnapshot.capture()
        var discovered: [DiscoveredSession] = []

        discovered += TerminalProcessSource(snapshot: processSnapshot).scan()
        discovered += ClaudeSessionSource(snapshot: processSnapshot).scanLive()
        discovered += await TranscriptSessionCache.shared.sessions(
            snapshot: processSnapshot,
            refreshInterval: transcriptRefreshInterval
        )
        discovered += await CodexAppServerSource.shared.scan()
        discovered += await MainActor.run { MacAppSource.scan() }

        return SessionTitleHeuristics.apply(to: SessionMerger.merge(discovered))
    }
}

private actor TranscriptSessionCache {
    static let shared = TranscriptSessionCache()

    private var cached: [DiscoveredSession] = []
    private var refreshedAt: Date = .distantPast

    func sessions(snapshot: ProcessSnapshot, refreshInterval: TimeInterval) -> [DiscoveredSession] {
        let now = Date()
        // Gate on "have we ever refreshed", not "is the cache empty" — an
        // legitimately empty result (quiet machine) must still be cached, or
        // every 1s tick re-enumerates three transcript directory trees.
        guard refreshedAt == .distantPast || now.timeIntervalSince(refreshedAt) >= refreshInterval else {
            return cached
        }

        cached = CodexTranscriptSource(snapshot: snapshot).scan()
            + ClaudeSessionSource(snapshot: snapshot).scanHistorical()
            + PiSessionSource(snapshot: snapshot).scan()
        refreshedAt = now
        return cached
    }
}
