import CProcInfo
import Darwin
import Foundation

// MARK: - Process Rows

struct TerminalIdentity: Sendable, Hashable {
    var name: String
    var bundleID: String?
    /// True when the "terminal" is really an agent host app (Claude Desktop,
    /// Codex.app). Shells running under these are the agent's own tool
    /// subprocesses, not user terminals, and must not become session rows.
    var isAgentHost: Bool = false
}

struct ProcessRow: Sendable, Hashable {
    let pid: Int
    let ppid: Int
    let pgid: Int
    /// Foreground process-group id of the controlling tty (`tpgid` in ps).
    /// Every row on a tty reports the same value; a row whose `pgid` equals it
    /// is part of what the user is interacting with right now.
    let tpgid: Int
    let stat: String
    /// Decaying-average CPU percentage from `ps` — the cheapest honest signal
    /// for "is this process actually doing work" without transcript access.
    let cpuPercent: Double
    let startDate: Date?
    let tty: String?
    let command: String

    var isForeground: Bool {
        stat.contains("+")
    }

    var executableName: String {
        guard let first = command.split(separator: " ").first else { return "" }
        let token = String(first)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return URL(fileURLWithPath: token).lastPathComponent
    }
}

// MARK: - Snapshot

/// One-shot capture of the process table. A single `ps` invocation provides
/// everything the scanner needs — tty ownership, foreground groups, CPU, and
/// start times — so a refresh tick never fans out into per-pid subprocesses.
struct ProcessSnapshot: Sendable {
    let rows: [ProcessRow]
    let byPID: [Int: ProcessRow]
    let children: [Int: [ProcessRow]]
    let rowsByTTY: [String: [ProcessRow]]

    static func capture(now: Date = Date()) -> ProcessSnapshot {
        let output = ProcessRunner.run(
            "/bin/ps",
            ["-axo", "pid=,ppid=,pgid=,tpgid=,stat=,%cpu=,etime=,tty=,command="]
        )
        return ProcessSnapshot(psOutput: output, now: now)
    }

    init(psOutput: String, now: Date = Date()) {
        let rows = psOutput
            .split(separator: "\n")
            .compactMap { ProcessSnapshot.parseProcessLine($0, now: now) }
        self.init(rows: rows)
    }

    init(rows: [ProcessRow]) {
        self.rows = rows
        self.byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        self.children = Dictionary(grouping: rows, by: \.ppid)
        self.rowsByTTY = Dictionary(grouping: rows.filter { $0.tty != nil }, by: { $0.tty ?? "" })
    }

    func descendants(of pid: Int) -> [ProcessRow] {
        var result: [ProcessRow] = []
        var queue = children[pid] ?? []
        var seen = Set<Int>()
        while let next = queue.first {
            queue.removeFirst()
            guard seen.insert(next.pid).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        return result
    }

    /// Combined CPU of a process and its whole subtree. Agent harnesses do
    /// most of their real work in children (tool subprocesses, node workers),
    /// so a subtree sum is the honest activity measure.
    func aggregateCPU(of pid: Int) -> Double {
        let own = byPID[pid]?.cpuPercent ?? 0
        return own + descendants(of: pid).reduce(0) { $0 + $1.cpuPercent }
    }

    /// The process the user is interacting with on `tty` — the row inside the
    /// tty's foreground process group. This is what `^C` would hit.
    func foregroundRow(for tty: String) -> ProcessRow? {
        let rows = rowsByTTY[tty] ?? []
        guard let tpgid = rows.first(where: { $0.tpgid > 0 })?.tpgid else {
            return rows.first(where: \.isForeground)
        }
        // Prefer the group leader, then any member of the foreground group,
        // then anything ps flags as foreground.
        return rows.first { $0.pid == tpgid }
            ?? rows.first { $0.pgid == tpgid && $0.isForeground }
            ?? rows.first { $0.pgid == tpgid }
            ?? rows.first(where: \.isForeground)
    }

    func terminalContext(for row: ProcessRow) -> TerminalIdentity? {
        if let direct = TerminalIdentityResolver.identity(for: row) {
            return direct
        }

        var current = row.ppid
        var depth = 0
        var seen = Set<Int>()
        while current > 1, depth < 40, !seen.contains(current) {
            seen.insert(current)
            guard let parent = byPID[current] else { break }
            if let terminal = TerminalIdentityResolver.identity(for: parent) {
                return terminal
            }
            current = parent.ppid
            depth += 1
        }

        return nil
    }

    /// Topmost process on a tty — the one whose parent lives outside the tty
    /// (usually the login shell). This is the right anchor for asking "who
    /// created this terminal".
    func ttyRootRow(for tty: String) -> ProcessRow? {
        let rows = rowsByTTY[tty] ?? []
        let pids = Set(rows.map(\.pid))
        return rows.filter { !pids.contains($0.ppid) }.min { $0.pid < $1.pid }
            ?? rows.min { $0.pid < $1.pid }
    }

    /// True when this process was spawned *by another agent* — a harness sits
    /// above it in the tree that isn't part of its own launcher chain.
    ///
    /// Wrapper chains are the subtlety: a harness is often launched through
    /// same-harness parents (shim script → node CLI). A contiguous run of
    /// same-harness ancestors directly above a harness process is its own
    /// plumbing, not a spawning agent. The chain breaks at the first
    /// non-harness ancestor; any harness found after that is a different
    /// agent's session doing the spawning.
    func isAgentSpawned(_ row: ProcessRow) -> Bool {
        let ownHarness = HarnessDetection.harness(for: row)
        var inOwnLauncherChain = ownHarness != nil
        var current = row.ppid
        var depth = 0
        var seen = Set<Int>()

        while current > 1, depth < 50, seen.insert(current).inserted {
            guard let ancestor = byPID[current] else { return false }
            if let ancestorHarness = HarnessDetection.harness(for: ancestor) {
                if !(inOwnLauncherChain && ancestorHarness == ownHarness) {
                    return true
                }
            } else {
                inOwnLauncherChain = false
            }
            current = ancestor.ppid
            depth += 1
        }
        return false
    }

    func isDescendant(_ pid: Int, of ancestor: Int) -> Bool {
        var current = pid
        var depth = 0
        while current > 1, depth < 60 {
            if current == ancestor { return true }
            guard let row = byPID[current] else { break }
            current = row.ppid
            depth += 1
        }
        return false
    }

    /// Returns `true` when any ancestor of `pid` has a command path inside
    /// `Codex.app`, indicating the process belongs to the Codex desktop app
    /// rather than a terminal shell.
    func isInsideCodexMacApp(pid: Int) -> Bool {
        var current = pid
        var depth = 0
        var seen = Set<Int>()
        while current > 1, depth < 50, seen.insert(current).inserted {
            guard let row = byPID[current] else { break }
            if row.command.contains("/Codex.app/") { return true }
            current = row.ppid
            depth += 1
        }
        return false
    }

    static func parseProcessLine(_ line: Substring, now: Date) -> ProcessRow? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]),
              let pgid = Int(parts[2]),
              let tpgid = Int(parts[3]) else {
            return nil
        }

        let elapsed = parseElapsedTime(parts[6])
        return ProcessRow(
            pid: pid,
            ppid: ppid,
            pgid: pgid,
            tpgid: tpgid,
            stat: String(parts[4]),
            cpuPercent: Double(parts[5]) ?? 0,
            startDate: elapsed.map { now.addingTimeInterval(-$0) },
            tty: DiscoveryHelpers.normalizedTTY(String(parts[7])),
            // maxSplits leaves the remainder raw, including the tty column's
            // padding for `??` rows — trim so prefix/equality checks work.
            command: String(parts[8]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// Parses ps `etime` — `[[dd-]hh:]mm:ss` — into seconds.
    static func parseElapsedTime(_ value: Substring) -> TimeInterval? {
        let dayParts = value.split(separator: "-")
        guard dayParts.count <= 2, let clock = dayParts.last else { return nil }

        var days = 0
        if dayParts.count == 2 {
            guard let parsed = Int(dayParts[0]) else { return nil }
            days = parsed
        }

        let fields = clock.split(separator: ":").map { Int($0) }
        guard fields.count >= 2, fields.count <= 3, !fields.contains(nil) else { return nil }
        let values = fields.compactMap { $0 }

        let seconds: Int
        switch values.count {
        case 2: seconds = values[0] * 60 + values[1]
        default: seconds = values[0] * 3600 + values[1] * 60 + values[2]
        }
        return TimeInterval(days * 86_400 + seconds)
    }
}

// MARK: - Terminal identity

enum TerminalIdentityResolver {
    /// Maps a process to the terminal app that hosts it, when the process is
    /// (or is inside) a known terminal's bundle.
    ///
    /// Order matters: Cmux ships an embedded `ghostty` binary inside
    /// `cmux.app/Contents/Resources/bin/`, so the Cmux check must run before
    /// the Ghostty executable-name check or every Cmux tab is misattributed
    /// to Ghostty (and focus clicks raise the wrong app).
    static func identity(for row: ProcessRow) -> TerminalIdentity? {
        let command = row.command.lowercased()
        let executable = row.executableName.lowercased()

        if command.contains("/cmux.app/") || executable == "cmux" {
            return TerminalIdentity(name: "Cmux", bundleID: "com.cmuxterm.app")
        }
        if executable == "terminal" || command.contains("/terminal.app/contents/macos/terminal") {
            return TerminalIdentity(name: "Terminal", bundleID: "com.apple.Terminal")
        }
        if executable == "iterm2" || executable == "iterm" || command.contains("/iterm.app/") || command.contains("/iterm2.app/") {
            return TerminalIdentity(name: "iTerm", bundleID: "com.googlecode.iterm2")
        }
        if executable == "ghostty" || command.contains("/ghostty.app/") {
            return TerminalIdentity(name: "Ghostty", bundleID: "com.mitchellh.ghostty")
        }
        if executable == "warp" || command.contains("/warp.app/") {
            return TerminalIdentity(name: "Warp", bundleID: "dev.warp.Warp-Stable")
        }
        if executable == "wezterm-gui" || executable == "wezterm" || command.contains("/wezterm.app/") {
            return TerminalIdentity(name: "WezTerm", bundleID: "com.github.wez.wezterm")
        }
        if executable == "kitty" || command.contains("/kitty.app/") {
            return TerminalIdentity(name: "Kitty", bundleID: "net.kovidgoyal.kitty")
        }
        if executable == "alacritty" || command.contains("/alacritty.app/") {
            return TerminalIdentity(name: "Alacritty", bundleID: "org.alacritty")
        }
        if command.contains("/claude.app/") {
            return TerminalIdentity(name: "Claude", bundleID: "com.anthropic.claudefordesktop", isAgentHost: true)
        }
        if command.contains("/codex.app/") {
            return TerminalIdentity(name: "Codex", bundleID: "com.openai.codex", isAgentHost: true)
        }
        if command.contains("/visual studio code.app/") {
            return TerminalIdentity(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        }
        if command.contains("/cursor.app/") {
            return TerminalIdentity(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        }
        if command.contains("/windsurf.app/") {
            return TerminalIdentity(name: "Windsurf", bundleID: "com.exafunction.windsurf")
        }

        // Generic fallback: a shell whose ancestor is some other GUI app
        // (Emacs, a JetBrains IDE, an unlisted terminal) still deserves a
        // host label instead of vanishing from the list. Use the outermost
        // .app bundle on the path as the display name.
        if let generic = genericAppIdentity(fromCommand: row.command) {
            return generic
        }

        return nil
    }

    private static func genericAppIdentity(fromCommand command: String) -> TerminalIdentity? {
        // Match on the whole command: bundle paths routinely contain spaces
        // ("Foo Helper (Renderer).app"), so token-splitting loses the path.
        guard command.contains(".app/Contents/MacOS/") else { return nil }

        // Outermost bundle, not the innermost: Electron helpers live at
        // Foo.app/Contents/Frameworks/Foo Helper.app/... and "Foo" is the
        // name users recognize.
        guard let range = command.range(of: ".app/") else { return nil }
        let prefix = command[..<range.lowerBound]
        guard let name = prefix.split(separator: "/").last, !name.isEmpty else { return nil }
        return TerminalIdentity(name: String(name), bundleID: nil)
    }
}

// MARK: - Process utilities

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) -> String {
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

    @discardableResult
    static func runWithStatus(_ executable: String, _ arguments: [String]) -> Bool {
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

    /// Current working directory via libproc — a single syscall instead of
    /// an `lsof` subprocess. Falls back to `lsof` for processes libproc
    /// refuses (different euid, zombies).
    static func cwd(for pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let written = proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size)
        if written >= size {
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if let path, !path.isEmpty {
                return path
            }
        }

        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.first == "n" else { return nil }
                return String(line.dropFirst())
            }
            .first
    }

    static func isAlive(pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
