import AppKit
import ApplicationServices
import Darwin

/// Closes the terminal window/tab backing a session.
///
/// Strategy:
///   1. Prefer terminal-native tab/session close by tty or AX window match.
///   2. Only send SIGTERM to a process group after the caller explicitly
///      allows destructive termination and the pid is the process-group owner.
@MainActor
enum TerminalCloseService {
    @discardableResult
    static func close(_ session: AgentSession, allowProcessTermination: Bool = false) -> Bool {
        guard session.closeCapability.canClose else { return false }

        if closeTerminalSession(session) {
            return true
        }

        guard allowProcessTermination,
              let pid = session.pid,
              let processGroupID = verifiedProcessGroupID(for: pid) else {
            return false
        }

        return kill(-processGroupID, SIGTERM) == 0 || errno == ESRCH
    }

    private static func closeTerminalSession(_ session: AgentSession) -> Bool {
        let terminal = session.terminalName.flatMap(TerminalApp.match)

        switch terminal {
        case .terminal:
            if let tty = session.tty, closeTerminalAppTab(tty: tty) { return true }
        case .iterm:
            if let tty = session.tty, closeITermSession(tty: tty) { return true }
        case .ghostty:
            if closeAXWindow(for: .ghostty, session: session) { return true }
        case .warp, .wezterm, .kitty, .alacritty:
            if let terminal, closeAXWindow(for: terminal, session: session) { return true }
        case .none:
            break
        }

        return false
    }

    private static func verifiedProcessGroupID(for pid: Int) -> pid_t? {
        let processID = pid_t(pid)
        guard processID > 1, kill(processID, 0) == 0 || errno != ESRCH else { return nil }

        let processGroupID = getpgid(processID)
        guard processGroupID > 1,
              processGroupID == processID,
              processGroupID != getpgrp() else {
            return nil
        }

        return processGroupID
    }

    // MARK: - Accessibility close

    private static func closeAXWindow(for terminal: TerminalApp, session: AgentSession) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        // Find the best matching window using the same scoring as focus
        let matches = windows.compactMap { window -> (window: AXUIElement, score: Int)? in
            let title = stringAttribute(kAXTitleAttribute, from: window) ?? ""
            let document = stringAttribute(kAXDocumentAttribute, from: window)
            let score = scoreWindow(title: title, document: document, session: session)
            guard score > 0 else { return nil }
            return (window, score)
        }
        .sorted { $0.score > $1.score }

        guard let match = matches.first else { return false }

        // Try to find and press the close button
        var closeButtonValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(match.window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
           let closeButtonValue,
           CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() {
            let closeButton = closeButtonValue as! AXUIElement
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success { return true }
        }

        // Fallback: raise the window and send Cmd+W
        _ = AXUIElementPerformAction(match.window, kAXRaiseAction as CFString)
        _ = app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            sendCmdW()
        }
        return true
    }

    private static func sendCmdW() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // 13 = 'w' keycode
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - AppleScript close

    private static func closeTerminalAppTab(tty: String) -> Bool {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t as string) is equal to "\(escaped)" then
                  close t
                  return true
                end if
              end try
            end repeat
          end repeat
        end tell
        return false
        """
        return runAppleScript(source)
    }

    private static func closeITermSession(tty: String) -> Bool {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s as string) is equal to "\(escaped)" then
                    close s
                    return true
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
        return runAppleScript(source)
    }

    // MARK: - Helpers

    private static func scoreWindow(title: String, document: String?, session: AgentSession) -> Int {
        let normalizedTitle = title.lowercased()
        let normalizedProject = session.projectName.lowercased()
        let normalizedCWD = normalizedPath(expandingHomeIn(session.cwd))
        let documentPath = document.flatMap(pathFromDocument).map(normalizedPath)

        var score = 0
        if let documentPath, documentPath == normalizedCWD {
            score += 100
        }
        if normalizedTitle.contains(normalizedProject) {
            score += 40
        }
        if normalizedTitle.contains(session.title.lowercased().prefix(20)) {
            score += 30
        }
        return score
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func pathFromDocument(_ document: String) -> String? {
        if let url = URL(string: document), url.isFileURL { return url.path }
        return nil
    }

    private static func expandingHomeIn(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
