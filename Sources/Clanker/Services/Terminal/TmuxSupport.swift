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
        let output = run(tmux, [
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
        _ = runWithStatus(tmux, ["select-window", "-t", windowTarget])
        return runWithStatus(tmux, ["select-pane", "-t", target])
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

        let resolved = run("/usr/bin/which", ["tmux"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty,
              FileManager.default.isExecutableFile(atPath: resolved) else {
            return nil
        }
        return resolved
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func runWithStatus(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func normalizedTTY(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        if trimmed.hasPrefix("tty") { return "/dev/\(trimmed)" }
        return "/dev/tty\(trimmed)"
    }

    private static func nonEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
