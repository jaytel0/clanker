import Foundation

struct TmuxPane: Equatable, Sendable {
    var session: String
    var window: String
    var pane: String
    var pid: Int
    var tty: String?
    var cwd: String?

    var paneAddress: String {
        "\(window).\(pane)"
    }

    var target: String {
        "\(session):\(paneAddress)"
    }
}

enum TmuxSupport {
    static func listPanes() -> [TmuxPane] {
        guard let tmux = tmuxPath() else { return [] }
        let output = ProcessRunner.run(tmux, [
            "list-panes",
            "-a",
            "-F",
            "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}"
        ])

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parsePaneLine(String($0)) }
    }

    @discardableResult
    static func select(session: String, pane: String) -> Bool {
        select(target: "\(session):\(pane)")
    }

    @discardableResult
    static func select(target: String) -> Bool {
        guard let tmux = tmuxPath() else { return false }
        let windowTarget = target.lastIndex(of: ".")
            .map { String(target[..<$0]) }
            ?? target
        _ = ProcessRunner.runWithStatus(tmux, ["select-window", "-t", windowTarget])
        return ProcessRunner.runWithStatus(tmux, ["select-pane", "-t", target])
    }

    /// Types `text` into the pane and presses Enter. `-l` sends the text
    /// literally (no key-name interpretation) so replies containing words
    /// like "Enter" or semicolons arrive verbatim.
    @discardableResult
    static func sendText(_ text: String, to target: String, pressReturn: Bool = true) -> Bool {
        guard let tmux = tmuxPath() else { return false }
        guard ProcessRunner.runWithStatus(tmux, ["send-keys", "-t", target, "-l", "--", text]) else {
            return false
        }
        guard pressReturn else { return true }
        return ProcessRunner.runWithStatus(tmux, ["send-keys", "-t", target, "Enter"])
    }

    static func parsePaneLine(_ line: String) -> TmuxPane? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 6,
              let pid = Int(parts[3]) else {
            return nil
        }

        return TmuxPane(
            session: String(parts[0]),
            window: String(parts[1]),
            pane: String(parts[2]),
            pid: pid,
            tty: normalizedTTY(String(parts[4])),
            cwd: nonEmpty(String(parts[5]))
        )
    }

    private static func tmuxPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let resolved = ProcessRunner.run("/usr/bin/which", ["tmux"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty,
              FileManager.default.isExecutableFile(atPath: resolved) else {
            return nil
        }
        return resolved
    }

    private static func normalizedTTY(_ raw: String) -> String? {
        DiscoveryHelpers.normalizedTTY(raw)
    }

    private static func nonEmpty(_ raw: String) -> String? {
        raw.nonEmpty
    }
}
