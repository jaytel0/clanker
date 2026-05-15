import Foundation

/// A repo discovered under one of the configured roots, scored by how recently
/// you've been working in it.
///
/// Recency comes from three blended signals (see `RecentProjectScanner`):
///   1. `.git/` mtime (commits, checkouts, pulls, stages).
///   2. `chpwd` log (Phase 2 — captures pure browsing).
///   3. Live agent sessions whose cwd is inside the repo.
struct RecentProject: Identifiable, Equatable, Hashable, Sendable {
    /// Absolute path to the repo root. Doubles as identity — paths are unique.
    let path: String

    /// Folder name (last path component).
    let name: String

    /// Category label — basename of the parent root, e.g. `"personal"` or
    /// `"shopify"`. Purely for display.
    let category: String

    /// Combined recency score as a unix timestamp. Newer = higher.
    let score: Date

    /// Inferred from `git remote get-url origin` if it points at github.com.
    /// Nil when the repo has no remote, a non-github remote, or the remote
    /// could not be parsed.
    let githubURL: URL?

    /// True if any live `AgentSession` is currently running inside this repo.
    /// Joined in by `RecentProjectsStore` from the session store, not by the
    /// scanner itself.
    var hasActiveSession: Bool

    var id: String { path }
}
