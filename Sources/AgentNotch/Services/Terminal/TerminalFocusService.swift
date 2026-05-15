import AppKit
import ApplicationServices
import Foundation

/// Routes a session back to the terminal/window that owns it.
///
/// Strategy (matching spec §14):
///   1. **Terminal.app / iTerm2** — drive AppleScript by tty so we focus the
///      *exact* tab/session, not just the app.
///   2. **Ghostty / Warp / WezTerm / Kitty / Alacritty** — use Accessibility
///      window metadata (`AXTitle` / `AXDocument`) to raise the best matching
///      window by cwd/project/harness, then fall back to app activation.
///   3. **Unknown** — best-effort: activate by name if we can resolve a
///      bundle, otherwise no-op.
@MainActor
enum TerminalFocusService {
    @discardableResult
    static func focus(_ session: AgentSession) -> Bool {
        if let launchURL = session.launchURL,
           let url = URL(string: launchURL),
           NSWorkspace.shared.open(url) {
            return true
        }

        let terminal = session.terminalName.flatMap(TerminalApp.match)
        switch terminal {
        case .terminal:
            if let tty = session.tty, focusTerminalApp(tty: tty) { return true }
            return activate(bundleID: TerminalApp.terminal.bundleID)

        case .iterm:
            if let tty = session.tty, focusITerm(tty: tty) { return true }
            return activate(bundleID: TerminalApp.iterm.bundleID)

        case .ghostty, .warp, .wezterm, .kitty, .alacritty:
            guard let terminal else { return false }
            if focusAXWindow(for: terminal, session: session) { return true }
            return activate(bundleID: terminal.bundleID)

        case .none:
            if let bundleID = session.appBundleID, activate(bundleID: bundleID) {
                return true
            }

            // Last resort: if we have a name, try to launch/activate by it.
            if let name = session.terminalName {
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

    // MARK: - Accessibility focus

    private static func focusAXWindow(for terminal: TerminalApp, session: AgentSession) -> Bool {
        guard isAccessibilityTrusted(promptIfNeeded: true) else {
            return false
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID).first else {
            return false
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        let matches = windows.compactMap { window -> (window: AXUIElement, score: Int)? in
            let title = stringAttribute(kAXTitleAttribute, from: window) ?? ""
            let document = stringAttribute(kAXDocumentAttribute, from: window)
            let score = scoreWindow(title: title, document: document, session: session)
            guard score > 0 else { return nil }
            return (window, score)
        }
        .sorted { $0.score > $1.score }

        guard let match = matches.first else { return false }

        _ = app.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(match.window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(match.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(match.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func scoreWindow(title: String, document: String?, session: AgentSession) -> Int {
        let normalizedTitle = title.lowercased()
        let normalizedProject = session.projectName.lowercased()
        let normalizedCWD = normalizedPath(expandingHomeIn(session.cwd))
        let documentPath = document.flatMap(pathFromDocument).map(normalizedPath)
        let isPiWindow = normalizedTitle.contains("π") || normalizedTitle.contains(" pi")

        var score = 0
        if let documentPath, documentPath == normalizedCWD {
            score += 100
        }
        if normalizedTitle.contains(normalizedProject) {
            score += 40
        }

        switch session.harness {
        case .pi:
            if isPiWindow { score += 25 }
        case .codex, .claude, .terminal:
            if !isPiWindow { score += 15 }
        }

        return score
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        guard promptIfNeeded else { return false }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func pathFromDocument(_ document: String) -> String? {
        if let url = URL(string: document), url.isFileURL {
            return url.path
        }
        return nil
    }

    private static func expandingHomeIn(_ path: String) -> String {
        if path == "~" {
            return NSHomeDirectory()
        }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst())
        }
        return path
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
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
        let result = script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            NSLog("[AgentNotch] AppleScript focus error: %@", error)
            #endif
            return false
        }
        return result.stringValue != "false"
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
