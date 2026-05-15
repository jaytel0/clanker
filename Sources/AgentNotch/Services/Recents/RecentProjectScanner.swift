import Foundation

/// Walks the configured roots, finds git repos, and scores them by recency.
///
/// Cheap enough to run on a background queue every minute — for a few hundred
/// repos it's a handful of `stat` calls plus one `git config` shell-out per
/// repo (cached after first scan via `GithubURLCache`).
enum RecentProjectScanner {
    /// Pure scan — no live-session join. The caller (`RecentProjectsStore`)
    /// owns layering on `hasActiveSession`.
    static func scan(roots: [String]) -> [RecentProject] {
        let cdMap = CdLog.mostRecentByPath()
        var results: [RecentProject] = []
        results.reserveCapacity(64)

        for root in roots {
            let expanded = expandHome(root)
            let category = (expanded as NSString).lastPathComponent
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
                continue
            }
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                let repoPath = (expanded as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDir),
                      isDir.boolValue else {
                    continue
                }
                guard isGitRepo(at: repoPath) else { continue }

                let score = scoreFor(repoPath: repoPath, cdMap: cdMap)
                let github = GithubURLCache.shared.url(for: repoPath)
                results.append(
                    RecentProject(
                        path: repoPath,
                        name: entry,
                        category: category,
                        score: score,
                        githubURL: github,
                        hasActiveSession: false
                    )
                )
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Recency scoring

    /// Combine git mtimes with the most recent `chpwd` event to produce a
    /// single ordering timestamp. Choose `max` rather than a weighted sum so
    /// any single strong signal (you literally just cd'd here, OR you just
    /// committed here) wins.
    private static func scoreFor(repoPath: String, cdMap: [String: Date]) -> Date {
        var best = gitMTime(repoPath: repoPath)
        if let cd = mostRecentCd(repoPath: repoPath, cdMap: cdMap), cd > best {
            best = cd
        }
        return best
    }

    /// Latest mtime across the handful of `.git/` files that change as you
    /// work: index updates on `git add`, logs/HEAD on commit/checkout, HEAD
    /// on branch switch, FETCH_HEAD on fetch/pull.
    private static func gitMTime(repoPath: String) -> Date {
        let dotGit = (repoPath as NSString).appendingPathComponent(".git")
        let candidates = [
            "index",
            "logs/HEAD",
            "HEAD",
            "FETCH_HEAD",
            "ORIG_HEAD"
        ]
        var best = Date.distantPast
        for candidate in candidates {
            let path = (dotGit as NSString).appendingPathComponent(candidate)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }
            if mtime > best { best = mtime }
        }
        // If `.git` is itself a file (worktrees / submodules), fall back to
        // its own mtime so the repo still ranks instead of falling to epoch 0.
        if best == .distantPast {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dotGit),
               let mtime = attrs[.modificationDate] as? Date {
                best = mtime
            }
        }
        return best
    }

    /// Take the newest `chpwd` event whose logged path is at or beneath
    /// `repoPath`. cd'ing into a subfolder of the repo still bumps the repo.
    private static func mostRecentCd(repoPath: String, cdMap: [String: Date]) -> Date? {
        guard !cdMap.isEmpty else { return nil }
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        var best: Date?
        for (path, date) in cdMap {
            let matches = path == repoPath || path.hasPrefix(prefix)
            guard matches else { continue }
            if let current = best {
                if date > current { best = date }
            } else {
                best = date
            }
        }
        return best
    }

    // MARK: - Repo detection

    private static func isGitRepo(at path: String) -> Bool {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit)
    }

    private static func expandHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }
}

/// Caches the parsed github.com URL for each repo. Shelling out to `git
/// config` per scan tick would be wasteful — origin URLs basically never
/// change after the first clone.
final class GithubURLCache: @unchecked Sendable {
    static let shared = GithubURLCache()

    private let queue = DispatchQueue(label: "agentnotch.github-url-cache")
    private var cache: [String: URL?] = [:]

    func url(for repoPath: String) -> URL? {
        if let cached = queue.sync(execute: { cache[repoPath] }) {
            return cached
        }
        let resolved = Self.resolve(repoPath: repoPath)
        queue.sync { cache[repoPath] = resolved }
        return resolved
    }

    private static func resolve(repoPath: String) -> URL? {
        let raw = git(args: ["-C", repoPath, "config", "--get", "remote.origin.url"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return GithubRemoteParser.parse(raw)
    }

    private static func git(args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        // Prefer `/usr/bin/git` (always present on macOS via the developer
        // tools shim). If the user has a custom git in `/opt/homebrew` etc.,
        // it will still work because both speak the same `config --get`.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Translates `git remote get-url origin` output into a browser URL.
///
/// Supports the four common github.com remote shapes — covers `git@`,
/// `https://`, `ssh://`, and `git://`. Non-github remotes return nil; the row
/// renders the GitHub action disabled in that case.
enum GithubRemoteParser {
    static func parse(_ remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // git@github.com:Org/Repo(.git)
        if trimmed.hasPrefix("git@github.com:") {
            let body = String(trimmed.dropFirst("git@github.com:".count))
            return makeURL(orgRepo: stripDotGit(body))
        }

        // ssh://git@github.com/Org/Repo(.git)
        if let scheme = ["ssh://git@github.com/", "git://github.com/"].first(where: trimmed.hasPrefix) {
            let body = String(trimmed.dropFirst(scheme.count))
            return makeURL(orgRepo: stripDotGit(body))
        }

        // https://github.com/Org/Repo(.git) — also tolerate http and an
        // optional `user@` prefix some setups produce.
        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "github.com" {
            let body = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            return makeURL(orgRepo: stripDotGit(body))
        }

        return nil
    }

    private static func stripDotGit(_ value: String) -> String {
        value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    private static func makeURL(orgRepo: String) -> URL? {
        let trimmed = orgRepo.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, trimmed.contains("/") else { return nil }
        return URL(string: "https://github.com/\(trimmed)")
    }
}
