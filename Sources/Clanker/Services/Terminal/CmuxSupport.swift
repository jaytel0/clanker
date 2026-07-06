import Foundation

/// One terminal panel inside Cmux, as recorded in its session-state file.
struct CmuxPanel: Equatable, Sendable {
    var panelID: String
    var workspaceID: String
    var windowID: String
    /// Normalized `/dev/ttysNNN` for the panel's shell.
    var tty: String?
    var cwd: String?
    var title: String?
    var workspaceTitle: String?
}

/// Bridge to Cmux (cmux.app) — an agent-oriented terminal that embeds
/// Ghostty surfaces inside Electron chrome.
///
/// Two integration points:
///   * **Discovery** — Cmux persists window/workspace/panel state (including
///     each panel's tty, cwd, and title) to a session-state JSON in
///     Application Support. Panels are matched to live shells by tty.
///   * **Focus** — Cmux ships a CLI (`Contents/Resources/bin/cmux`) that
///     talks to the running app over a Unix socket; `focus-panel` raises the
///     exact pane, which beats AppleScript/AX heuristics.
enum CmuxSupport {
    static let bundleID = "com.cmuxterm.app"
    static let appPath = "/Applications/cmux.app"

    private static let stateCache = FileParseCache<[CmuxPanel]>()

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    // MARK: - Panel discovery

    /// Panels from the most recent session-state file, keyed by tty.
    ///
    /// The state file is a restore snapshot, not a live registry — panels for
    /// ttys that no longer exist are harmless (nothing matches them), but a
    /// *recycled* tty could inherit a stale title. Callers guard against that
    /// by only trusting hints newer than the shell they decorate.
    static func panelsByTTY(stateFile: URL? = nil) -> [String: CmuxPanel] {
        guard let file = stateFile ?? currentStateFile() else { return [:] }
        let panels = stateCache.value(for: file, parse: parseStateFile) ?? []
        var byTTY: [String: CmuxPanel] = [:]
        for panel in panels {
            guard let tty = panel.tty else { continue }
            byTTY[tty] = panel
        }
        return byTTY
    }

    /// Modification date of the session-state file, used as the hint
    /// freshness bound.
    static func stateFileModificationDate(stateFile: URL? = nil) -> Date? {
        guard let file = stateFile ?? currentStateFile() else { return nil }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func currentStateFile() -> URL? {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
        let primary = supportDir.appendingPathComponent("session-\(bundleID).json")
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }

        // Fall back to the newest non-backup session file (debug builds use a
        // suffixed bundle id).
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: supportDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter {
                $0.lastPathComponent.hasPrefix("session-")
                    && $0.pathExtension == "json"
                    && !$0.lastPathComponent.contains("-previous")
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    static func parseStateFile(_ url: URL) -> [CmuxPanel]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = json["windows"] as? [[String: Any]] else {
            return nil
        }

        var panels: [CmuxPanel] = []
        for window in windows {
            let windowID = DiscoveryHelpers.string(window["windowId"]) ?? ""
            guard let tabManager = window["tabManager"] as? [String: Any],
                  let workspaces = tabManager["workspaces"] as? [[String: Any]] else {
                continue
            }

            for workspace in workspaces {
                let workspaceID = DiscoveryHelpers.string(workspace["workspaceId"]) ?? ""
                let workspaceTitle = DiscoveryHelpers.string(workspace["processTitle"])
                guard let rawPanels = workspace["panels"] as? [[String: Any]] else { continue }

                for rawPanel in rawPanels {
                    guard let panelID = DiscoveryHelpers.string(rawPanel["id"]) else { continue }
                    let terminal = rawPanel["terminal"] as? [String: Any]
                    let cwd = DiscoveryHelpers.string(terminal?["workingDirectory"])
                        ?? DiscoveryHelpers.string(rawPanel["directory"])
                    panels.append(CmuxPanel(
                        panelID: panelID,
                        workspaceID: workspaceID,
                        windowID: windowID,
                        tty: DiscoveryHelpers.string(rawPanel["ttyName"]).flatMap(normalizedTTY),
                        cwd: cwd,
                        title: usefulTitle(DiscoveryHelpers.string(rawPanel["title"])),
                        workspaceTitle: usefulTitle(workspaceTitle)
                    ))
                }
            }
        }
        return panels
    }

    /// Cmux defaults panel titles to an abbreviated path ("…/personal/apdraw");
    /// those carry no information beyond the cwd we already have.
    private static func usefulTitle(_ value: String?) -> String? {
        guard let value = value?.nonEmpty else { return nil }
        if value.hasPrefix("…") || value.hasPrefix("/") || value.hasPrefix("~") {
            return nil
        }
        return value
    }

    private static func normalizedTTY(_ raw: String) -> String? {
        DiscoveryHelpers.normalizedTTY(raw)
    }

    // MARK: - CLI control

    private static var cliPath: String? {
        let path = "\(appPath)/Contents/Resources/bin/cmux"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Whether the Cmux app's control socket is up (i.e. the app is running
    /// and accepting CLI commands).
    static var isSocketAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/state/cmux/cmux.sock").path,
            home.appendingPathComponent("Library/Application Support/cmux/cmux.sock").path
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Raise the exact pane via the Cmux CLI. Returns false when the app or
    /// its socket is unavailable so callers can fall back to AX focus.
    @discardableResult
    static func focusPanel(id panelID: String) -> Bool {
        guard let cliPath, isSocketAvailable else { return false }
        return ProcessRunner.runWithStatus(cliPath, ["focus-panel", "--panel", panelID])
    }

    /// Types `text` into the panel's terminal and presses Enter, all over the
    /// control socket — no window focus required.
    @discardableResult
    static func sendText(_ text: String, toPanel panelID: String, pressReturn: Bool = true) -> Bool {
        guard let cliPath, isSocketAvailable else { return false }
        guard ProcessRunner.runWithStatus(cliPath, ["send-panel", "--panel", panelID, text]) else {
            return false
        }
        guard pressReturn else { return true }
        // The CLI's key-name vocabulary isn't documented; try the common
        // spellings in order.
        return ProcessRunner.runWithStatus(cliPath, ["send-key-panel", "--panel", panelID, "enter"])
            || ProcessRunner.runWithStatus(cliPath, ["send-key-panel", "--panel", panelID, "return"])
            || ProcessRunner.runWithStatus(cliPath, ["send-panel", "--panel", panelID, "\n"])
    }
}
