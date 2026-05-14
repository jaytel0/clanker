import AppKit
import Foundation

/// Routes a session back to the terminal/window that owns it.
///
/// Strategy (matching spec §14):
///   1. **Terminal.app / iTerm2** — drive AppleScript by tty so we focus the
///      *exact* tab/session, not just the app.
///   2. **Ghostty / Warp / WezTerm / Kitty / Alacritty** — no first-party
///      session AppleScript surface, so activate the app by bundle id and the
///      OS will raise its key window. Better than nothing; degrades visibly.
///   3. **Unknown** — best-effort: activate by name if we can resolve a
///      bundle, otherwise no-op.
@MainActor
enum TerminalFocusService {
    @discardableResult
    static func focus(_ session: AgentSession) -> Bool {
        let terminal = session.terminalName.flatMap(TerminalApp.match)
        switch terminal {
        case .terminal:
            if let tty = session.tty, focusTerminalApp(tty: tty) { return true }
            return activate(bundleID: TerminalApp.terminal.bundleID)

        case .iterm:
            if let tty = session.tty, focusITerm(tty: tty) { return true }
            return activate(bundleID: TerminalApp.iterm.bundleID)

        case .ghostty, .warp, .wezterm, .kitty, .alacritty:
            return activate(bundleID: terminal!.bundleID)

        case .none:
            // Last resort: if we have a name, try to launch/activate by it.
            if let name = session.terminalName,
               let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/")) {
                _ = url
                return activate(byName: name)
            }
            return false
        }
    }

    // MARK: - App activation

    private static func activate(bundleID: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.activate(options: [.activateAllWindows])
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    private static func activate(byName name: String) -> Bool {
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        if let running { return running.activate(options: [.activateAllWindows]) }
        return false
    }

    // MARK: - AppleScript focus

    /// Focus the Terminal.app tab whose `tty` matches the session.
    private static func focusTerminalApp(tty: String) -> Bool {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t as string) is equal to "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  set index of w to 1
                  return
                end if
              end try
            end repeat
          end repeat
        end tell
        """
        return runAppleScript(source)
    }

    /// Focus the iTerm2 session whose `tty` matches.
    private static func focusITerm(tty: String) -> Bool {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s as string) is equal to "\(escaped)" then
                    select s
                    tell t to select
                    tell w to select
                    return
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        """
        return runAppleScript(source)
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            NSLog("[AgentNotch] AppleScript focus error: %@", error)
            #endif
            return false
        }
        return true
    }
}

// MARK: - Terminal registry

private enum TerminalApp {
    case terminal, iterm, ghostty, warp, wezterm, kitty, alacritty

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        }
    }

    static func match(_ displayName: String) -> TerminalApp? {
        switch displayName {
        case "Terminal": .terminal
        case "iTerm", "iTerm2": .iterm
        case "Ghostty": .ghostty
        case "Warp": .warp
        case "WezTerm": .wezterm
        case "Kitty": .kitty
        case "Alacritty": .alacritty
        default: nil
        }
    }
}
