import Foundation

/// Discovers live sessions from the process table: every tty with an
/// interactive shell or harness becomes a row, plus tty-less harnesses
/// (Mac-app children, daemonized agents).
struct TerminalProcessSource {
    let snapshot: ProcessSnapshot
    let tmuxPanes: [TmuxPane]
    let cmuxPanels: [String: CmuxPanel]
    let cmuxStateDate: Date?

    /// Subtree CPU at or above this is treated as "doing work". The threshold
    /// is deliberately above shell-prompt noise (~0%) and below streaming
    /// inference / tool execution (tens of percent).
    static let workingCPUThreshold = 8.0

    init(
        snapshot: ProcessSnapshot,
        tmuxPanes: [TmuxPane] = TmuxSupport.listPanes(),
        cmuxPanels: [String: CmuxPanel] = CmuxSupport.panelsByTTY(),
        cmuxStateDate: Date? = CmuxSupport.stateFileModificationDate()
    ) {
        self.snapshot = snapshot
        self.tmuxPanes = tmuxPanes
        self.cmuxPanels = cmuxPanels
        self.cmuxStateDate = cmuxStateDate
    }

    func scan() -> [DiscoveredSession] {
        var sessions: [DiscoveredSession] = []
        var coveredPIDs = Set<Int>()

        for (tty, rows) in snapshot.rowsByTTY {
            guard let session = sessionForTTY(tty, rows: rows) else { continue }
            if let pid = session.pid {
                coveredPIDs.insert(pid)
            }
            sessions.append(session)
        }

        sessions += orphanHarnessSessions(excluding: coveredPIDs)
        return sessions
    }

    // MARK: - Per-tty session

    private func sessionForTTY(_ tty: String, rows: [ProcessRow]) -> DiscoveredSession? {
        let terminal = rows.compactMap { snapshot.terminalContext(for: $0) }.first
        let shellRow = bestShell(in: rows)

        // Pick the harness the *user actually invoked* in this tab. The
        // foreground process group is ground truth for "what's running in
        // this terminal" — walk the parent chain from there and grab the
        // first harness. Nested harnesses (pi spawning codex, node wrappers
        // spawning vendor binaries) sit *below* the user's harness in the
        // tree, so the upward walk lands on the right one.
        let foregroundRow = snapshot.foregroundRow(for: tty)
        let harnessRow = harnessRowFromForeground(
            foregroundPid: foregroundRow?.pid,
            rows: rows
        )
        let owner = harnessRow ?? shellRow ?? rows.sorted { $0.pid > $1.pid }.first

        let tmuxPane = tmuxPane(containing: harnessRow?.pid ?? foregroundRow?.pid ?? owner?.pid)
        guard terminal != nil || harnessRow != nil || tmuxPane != nil else { return nil }
        guard let owner else { return nil }
        guard shellRow != nil || harnessRow != nil else { return nil }

        let harness = harnessRow.flatMap(HarnessDetection.harness(for:)) ?? .terminal

        // Agent-spawned infrastructure is not a user session. Two spawn
        // paths produce phantom rows without this:
        //   * a CLI agent allocates ptys for its tool shells — the tty's
        //     root process then has that agent above it in the tree;
        //   * a desktop agent app (Claude.app, Codex.app) runs its tool
        //     shells as direct children — the identity walk lands on the
        //     agent host, not a terminal.
        let rootRow = snapshot.ttyRootRow(for: tty) ?? owner
        if snapshot.isAgentSpawned(rootRow) { return nil }
        if harness == .terminal, terminal?.isAgentHost == true { return nil }

        // cwd preference: tmux pane (exact) → foreground process → harness →
        // shell. The foreground process answers "where am I" the way the
        // user sees it.
        let processCWD = [foregroundRow?.pid, harnessRow?.pid, owner.pid]
            .compactMap { $0 }
            .lazy
            .compactMap { ProcessRunner.cwd(for: $0) }
            .first
        let cmuxPanel = freshCmuxPanel(
            forTTY: tty,
            terminal: terminal,
            ownerStart: owner.startDate,
            processCWD: processCWD
        )
        let cwd = tmuxPane?.cwd ?? processCWD ?? cmuxPanel?.cwd ?? NSHomeDirectory()

        let status = liveStatus(for: harness, anchorPID: harnessRow?.pid ?? owner.pid)
        let title = titleForTTY(
            harness: harness,
            foregroundRow: foregroundRow,
            owner: owner,
            cmuxPanel: cmuxPanel
        )
        let preview = terminal.map { "\($0.name) PID \(owner.pid)" } ?? "PID \(owner.pid)"

        let sessionKey = tmuxPane
            .map { "\(harness.rawValue):tmux:\($0.target)" }
            ?? "\(harness.rawValue):tty:\(tty)"
        let terminalContext = TerminalContext(
            terminalBundleID: terminal?.bundleID,
            terminalProgram: terminal?.name,
            terminalSessionID: cmuxPanel?.panelID,
            iTermSessionID: nil,
            tty: tty,
            tmuxSession: tmuxPane?.session,
            tmuxPane: tmuxPane?.paneAddress,
            cwd: tmuxPane?.cwd ?? cwd,
            source: tmuxPane == nil ? .process : .tmux,
            confidence: (tmuxPane != nil || cmuxPanel != nil) ? .high : .medium
        )

        return DiscoveredSession(
            sessionKey: sessionKey,
            sourceKind: .process,
            id: "\(harness.rawValue)-\(DiscoveryHelpers.identifierSafe(sessionKey))",
            title: title,
            cwd: cwd,
            harness: harness,
            status: status,
            preview: preview,
            lastActivity: (harnessRow ?? owner).startDate ?? Date(),
            pid: harnessRow?.pid ?? owner.pid,
            terminalName: terminal?.name,
            tty: tty,
            terminalContext: terminalContext,
            appBundleID: terminal?.bundleID,
            launchURL: nil
        )
    }

    /// Pick the harness rooted closest to the user's prompt for this tty:
    /// walk the parent chain up from the foreground process; the first
    /// harness on that walk is the one the user typed. Fall back to the
    /// lowest-PID harness on the tty (nested/child harnesses spawn later).
    func harnessRowFromForeground(foregroundPid: Int?, rows: [ProcessRow]) -> ProcessRow? {
        if let foregroundPid {
            var pid = foregroundPid
            var depth = 0
            while depth < 40, let row = snapshot.byPID[pid] {
                if HarnessDetection.isHarnessProcess(row) { return row }
                if pid == row.ppid { break }
                pid = row.ppid
                depth += 1
            }
        }
        return rows.sorted { $0.pid < $1.pid }.first(where: HarnessDetection.isHarnessProcess)
    }

    private func titleForTTY(
        harness: HarnessID,
        foregroundRow: ProcessRow?,
        owner: ProcessRow,
        cmuxPanel: CmuxPanel?
    ) -> String {
        if harness != .terminal {
            return harness.defaultSessionTitle
        }
        // A user-renamed Cmux tab is the best label a bare shell can have.
        if let panelTitle = cmuxPanel?.title ?? cmuxPanel?.workspaceTitle {
            return panelTitle
        }
        // Otherwise name the row after what's actually running: `vim`,
        // `npm run dev`, or the shell itself.
        let executable = foregroundRow?.executableName ?? owner.executableName
        return executable.nonEmpty ?? "Terminal"
    }

    /// Status for a live process-backed row. Transcript sources refine this
    /// during merge; CPU keeps rows honest for harnesses without transcripts
    /// (opencode, gemini, cursor) and between transcript refreshes.
    private func liveStatus(for harness: HarnessID, anchorPID: Int) -> SessionStatusKind {
        let cpu = snapshot.aggregateCPU(of: anchorPID)
        if cpu >= Self.workingCPUThreshold {
            return .working
        }
        return harness == .terminal ? .idle : .active
    }

    /// Only trust Cmux state-file hints that agree with live process facts.
    /// The state file is a restore snapshot: ttys get recycled across app
    /// launches and can even appear twice, so a hint must be newer than the
    /// shell it decorates *and* point at the same working directory before
    /// its title/panel-id are attached.
    private func freshCmuxPanel(
        forTTY tty: String,
        terminal: TerminalIdentity?,
        ownerStart: Date?,
        processCWD: String?
    ) -> CmuxPanel? {
        guard terminal?.bundleID == CmuxSupport.bundleID,
              let panel = cmuxPanels[tty] else {
            return nil
        }
        guard let cmuxStateDate else { return nil }
        if let ownerStart, cmuxStateDate < ownerStart {
            return nil
        }
        if let processCWD {
            // A panel record without a cwd can't prove it describes this
            // shell — treat missing as disagreement, not as a wildcard.
            guard let panelCWD = panel.cwd,
                  DiscoveryHelpers.normalizedPath(processCWD) == DiscoveryHelpers.normalizedPath(panelCWD) else {
                return nil
            }
        }
        return panel
    }

    // MARK: - Orphan harnesses (no tty)

    private func orphanHarnessSessions(excluding coveredPIDs: Set<Int>) -> [DiscoveredSession] {
        snapshot.rows.compactMap { row -> DiscoveredSession? in
            guard !coveredPIDs.contains(row.pid),
                  row.tty == nil,
                  let harness = HarnessDetection.harness(for: row),
                  !HarnessDetection.isCodexAppServerProcess(row),
                  // An agent spawned by another agent (companion runtimes,
                  // nested `codex exec` tool calls) is that agent's work,
                  // not a session of its own.
                  !snapshot.isAgentSpawned(row) else {
                return nil
            }

            let cwd = ProcessRunner.cwd(for: row.pid) ?? NSHomeDirectory()

            // A no-tty Codex process whose ancestor chain includes Codex.app
            // is running inside the Mac app, not a terminal. Route it there.
            let codexMacAppInfo: (bundleID: String?, launchURL: String?)
            if harness == .codex, snapshot.isInsideCodexMacApp(pid: row.pid) {
                let threadID = CodexTranscriptIndex.shared.threadID(forCWD: cwd)
                codexMacAppInfo = (
                    bundleID: "com.openai.codex",
                    launchURL: threadID.map { "codex://threads/\($0)" }
                )
            } else {
                codexMacAppInfo = (nil, nil)
            }

            let tmuxPane = tmuxPane(containing: row.pid)
            let sessionKey = tmuxPane
                .map { "\(harness.rawValue):tmux:\($0.target)" }
                ?? "\(harness.rawValue):pid:\(row.pid)"
            let terminalContext = TerminalContext(
                terminalBundleID: nil,
                terminalProgram: nil,
                terminalSessionID: nil,
                iTermSessionID: nil,
                tty: tmuxPane?.tty,
                tmuxSession: tmuxPane?.session,
                tmuxPane: tmuxPane?.paneAddress,
                cwd: tmuxPane?.cwd ?? cwd,
                source: tmuxPane == nil ? .process : .tmux,
                confidence: tmuxPane == nil ? .low : .high
            )

            return DiscoveredSession(
                sessionKey: sessionKey,
                sourceKind: .process,
                id: "\(harness.rawValue)-\(DiscoveryHelpers.identifierSafe(sessionKey))",
                title: harness.defaultSessionTitle,
                cwd: tmuxPane?.cwd ?? cwd,
                harness: harness,
                status: liveStatus(for: harness, anchorPID: row.pid),
                preview: "PID \(row.pid)",
                lastActivity: row.startDate ?? Date(),
                pid: row.pid,
                terminalName: nil,
                tty: nil,
                terminalContext: terminalContext,
                appBundleID: codexMacAppInfo.bundleID,
                launchURL: codexMacAppInfo.launchURL
            )
        }
    }

    private func tmuxPane(containing pid: Int?) -> TmuxPane? {
        guard let pid else { return nil }
        return tmuxPanes.first {
            $0.pid == pid || snapshot.isDescendant(pid, of: $0.pid)
        }
    }

    private func bestShell(in rows: [ProcessRow]) -> ProcessRow? {
        rows
            .filter { Self.isInteractiveShell($0) }
            .sorted { lhs, rhs in
                if lhs.ppid != rhs.ppid {
                    return lhs.ppid > rhs.ppid
                }
                return lhs.pid > rhs.pid
            }
            .first
    }

    static func isInteractiveShell(_ row: ProcessRow) -> Bool {
        let executable = row.executableName.lowercased()
        return ["zsh", "bash", "fish", "nu", "sh", "ksh", "tcsh", "csh", "pwsh", "xonsh", "elvish"].contains(executable)
    }
}

// MARK: - Mac apps without process-level sessions

import AppKit

@MainActor
enum MacAppSource {
    static func scan() -> [DiscoveredSession] {
        var sessions: [DiscoveredSession] = []
        let apps = NSWorkspace.shared.runningApplications

        if let codex = apps.first(where: { $0.bundleIdentifier == "com.openai.codex" }) {
            sessions.append(DiscoveredSession(
                sessionKey: "codex:app-running",
                sourceKind: .app,
                id: "codex-app-running",
                title: "Codex",
                cwd: NSHomeDirectory(),
                harness: .codex,
                status: .active,
                preview: "Codex app is running",
                lastActivity: codex.launchDate ?? Date(),
                pid: Int(codex.processIdentifier),
                terminalName: nil,
                tty: nil,
                appBundleID: codex.bundleIdentifier,
                launchURL: nil
            ))
        }

        return sessions
    }
}
