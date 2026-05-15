import AppKit
import Foundation

/// Opens a project folder in the user's preferred terminal.
@MainActor
enum TerminalLauncher {
    static var preferredApp: TerminalApp {
        TerminalApp.resolving(bundleID: RecentsSettings.shared.preferredTerminalBundleID)
    }

    static var preferredDisplayName: String {
        preferredApp.displayName
    }

    @discardableResult
    static func openProject(at path: String) -> Bool {
        let terminal = preferredApp
        if openProject(at: path, in: terminal) {
            return true
        }

        // If a third-party terminal was removed or rejected the launch args,
        // still land the user in a useful shell instead of Finder.
        if terminal != .terminal {
            return openProject(at: path, in: .terminal)
        }
        return false
    }

    @discardableResult
    private static func openProject(at path: String, in terminal: TerminalApp) -> Bool {
        switch terminal {
        case .terminal:
            return openTerminalApp(at: path)
        case .iterm:
            return openITerm(at: path)
        case .ghostty:
            return openGhostty(at: path)
        case .warp:
            return openWarp(at: path)
        case .wezterm:
            return runBundledExecutable(
                app: terminal,
                executableNames: ["wezterm", "wezterm-gui"],
                arguments: ["start", "--cwd", path]
            )
        case .kitty:
            return runBundledExecutable(
                app: terminal,
                executableNames: ["kitty"],
                arguments: ["--directory", path]
            )
        case .alacritty:
            return runBundledExecutable(
                app: terminal,
                executableNames: ["alacritty"],
                arguments: ["--working-directory", path]
            )
        }
    }

    private static func openTerminalApp(at path: String) -> Bool {
        let escapedPath = appleScriptEscaped(path)
        let source = """
        tell application "Terminal"
          activate
          set projectPath to "\(escapedPath)"
          do script "cd " & quoted form of projectPath
        end tell
        """
        return runAppleScript(source)
    }

    private static func openITerm(at path: String) -> Bool {
        guard TerminalApp.iterm.isInstalled else { return false }
        let escapedPath = appleScriptEscaped(path)
        let source = """
        tell application "iTerm"
          activate
          set projectPath to "\(escapedPath)"
          set newWindow to (create window with default profile)
          tell current session of newWindow
            write text "cd " & quoted form of projectPath
          end tell
        end tell
        """
        return runAppleScript(source)
    }

    /// Uses the CLI embedded in Ghostty.app. This opens a new window inside the
    /// existing Ghostty instance (no duplicate dock icons), or launches Ghostty
    /// if it is not already running.
    private static func openGhostty(at path: String) -> Bool {
        runBundledExecutable(
            app: .ghostty,
            executableNames: ["ghostty"],
            arguments: ["+new-window", "--working-directory=\(path)"],
            activateAfterLaunch: true
        )
    }

    private static func openWarp(at path: String) -> Bool {
        // Warp supports a URL action for creating a terminal at a path. If a
        // future Warp build changes this, the caller falls back to Terminal.app.
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_window"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func runBundledExecutable(
        app: TerminalApp,
        executableNames: [String],
        arguments: [String],
        activateAfterLaunch: Bool = false
    ) -> Bool {
        guard let appURL = app.appURL else { return false }

        let executableURL = executableNames
            .map { appURL.appendingPathComponent("Contents/MacOS/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executableURL else { return false }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            if activateAfterLaunch {
                activate(appURL: appURL)
            }
            return true
        } catch {
            return false
        }
    }

    private static func activate(appURL: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        }
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            NSLog("[Clanker] Terminal launch AppleScript error: %@", error)
            #endif
            return false
        }
        return true
    }
}
