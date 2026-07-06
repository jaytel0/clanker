import AppKit
import ApplicationServices
import Foundation

/// Delivers a user-typed reply into the terminal session that owns an agent,
/// so "Needs input" / "Needs approval" can be answered straight from the
/// notch or a notification without hunting for the window.
///
/// Delivery strategies, most-exact first:
///   1. **tmux** — `send-keys` to the known pane. No focus required.
///   2. **Cmux** — the bundled CLI's `send-panel` over the control socket.
///      No focus required.
///   3. **iTerm2** — AppleScript `write text` to the session matched by tty.
///      No focus required.
///   4. **Fallback** — focus the exact window via `TerminalFocusService`,
///      then post keyboard events *directly to the terminal app's pid*.
///      pid-targeted posting means a mis-focus can never leak keystrokes
///      into an unrelated app.
@MainActor
enum SessionReplyService {
    /// How the reply routing decided to deliver. Exposed for tests and for
    /// UI feedback copy.
    enum Route: Equatable {
        case tmux(target: String)
        case cmuxPanel(id: String)
        case iterm(tty: String)
        case keystrokes(bundleID: String)
        case none
    }

    static func route(for session: AgentSession) -> Route {
        if let target = session.terminalContext.tmuxTarget {
            return .tmux(target: target)
        }
        if session.terminalContext.terminalBundleID == CmuxSupport.bundleID,
           let panelID = session.terminalContext.terminalSessionID {
            return .cmuxPanel(id: panelID)
        }
        if session.terminalContext.terminalBundleID == TerminalApp.iterm.bundleID,
           let tty = session.tty ?? session.terminalContext.tty {
            return .iterm(tty: tty)
        }
        if let bundleID = session.terminalContext.terminalBundleID {
            return .keystrokes(bundleID: bundleID)
        }
        return .none
    }

    @discardableResult
    static func send(_ text: String, to session: AgentSession) -> Bool {
        let payload = text.trimmingCharacters(in: .newlines)
        guard !payload.isEmpty else { return false }

        switch route(for: session) {
        case .tmux(let target):
            if TmuxSupport.sendText(payload, to: target) { return true }
            return sendViaKeystrokes(payload, session: session)

        case .cmuxPanel(let panelID):
            if CmuxSupport.sendText(payload, toPanel: panelID) { return true }
            return sendViaKeystrokes(payload, session: session)

        case .iterm(let tty):
            if writeToITermSession(payload, tty: tty) { return true }
            return sendViaKeystrokes(payload, session: session)

        case .keystrokes:
            return sendViaKeystrokes(payload, session: session)

        case .none:
            return sendViaKeystrokes(payload, session: session)
        }
    }

    // MARK: - Keystroke fallback

    private static func sendViaKeystrokes(_ text: String, session: AgentSession) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let bundleID = session.terminalContext.terminalBundleID ?? session.appBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        let pid = app.processIdentifier
        // Raise the exact window first so the app's key window is the right
        // tab; the events themselves are pid-targeted, so even if focus
        // doesn't land, they can only reach this terminal app.
        TerminalFocusService.focus(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            KeystrokeSender.type(text, pressReturn: true, pid: pid)
        }
        return true
    }

    private static func writeToITermSession(_ text: String, tty: String) -> Bool {
        let escapedTTY = appleScriptEscaped(tty)
        let escapedText = appleScriptEscaped(text)
        let source = """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s as text) is equal to "\(escapedTTY)" then
                    tell s to write text "\(escapedText)"
                    return "true"
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return "false"
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.stringValue == "true"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Synthesizes typed text as CGEvents delivered to a specific pid.
@MainActor
enum KeystrokeSender {
    /// UTF-16 units per keyboard event. `keyboardSetUnicodeString` accepts
    /// longer strings, but small chunks behave consistently across apps.
    private static let chunkSize = 16

    static func type(_ text: String, pressReturn: Bool, pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            postUnicodeChunk(chunk, source: source, pid: pid)
            index += chunkSize
        }

        guard pressReturn else { return }
        // Small delay lets the app ingest the text before Return commits it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            postReturnKey(source: source, pid: pid)
        }
    }

    private static func postUnicodeChunk(_ units: [UniChar], source: CGEventSource, pid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        var mutableUnits = units
        down.keyboardSetUnicodeString(stringLength: mutableUnits.count, unicodeString: &mutableUnits)
        up.keyboardSetUnicodeString(stringLength: mutableUnits.count, unicodeString: &mutableUnits)
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private static func postReturnKey(source: CGEventSource, pid: pid_t) {
        let returnKeyCode: CGKeyCode = 36
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) else {
            return
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
