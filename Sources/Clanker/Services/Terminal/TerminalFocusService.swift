import AppKit
import ApplicationServices
import Darwin
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
        let terminal = session.terminalName.flatMap(TerminalApp.match)

        // Terminal-backed rows may also carry deep links from transcript or
        // app-server metadata. Prefer returning to the host terminal/window;
        // deep links are a fallback only when no host can be focused.
        if session.tty != nil || session.terminalName != nil {
            if focusHostApp(for: session, terminal: terminal) { return true }
            return openLaunchURL(session.launchURL)
        }

        if openLaunchURL(session.launchURL) {
            return true
        }

        return focusHostApp(for: session, terminal: terminal)
    }

    private static func focusHostApp(for session: AgentSession, terminal: TerminalApp?) -> Bool {
        switch terminal {
        case .terminal:
            if let tty = session.tty, focusTerminalApp(tty: tty) {
                switchToFrontWindowSpace(bundleID: TerminalApp.terminal.bundleID)
                return true
            }
            return activate(bundleID: TerminalApp.terminal.bundleID)

        case .iterm:
            if let tty = session.tty, focusITerm(tty: tty) {
                switchToFrontWindowSpace(bundleID: TerminalApp.iterm.bundleID)
                return true
            }
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

    private static func openLaunchURL(_ launchURL: String?) -> Bool {
        guard let launchURL,
              let url = URL(string: launchURL) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - App activation

    private static func activate(bundleID: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            _ = app.unhide()
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
        let running = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
        if let running {
            _ = running.unhide()
            return running.activate(options: [.activateAllWindows])
        }
        return false
    }

    // MARK: - Accessibility focus

    private static func switchToFrontWindowSpace(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return
        }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let window = (windowsValue as? [AXUIElement])?.first else {
            _ = app.activate(options: [.activateAllWindows])
            return
        }

        if let windowID = DesktopSpaceSwitcher.windowID(for: window) {
            DesktopSpaceSwitcher.switchToSpace(containingWindowID: windowID)
        }
        _ = app.unhide()
        _ = AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = app.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func focusAXWindow(for terminal: TerminalApp, session: AgentSession) -> Bool {
        guard isAccessibilityTrusted(promptIfNeeded: false) else {
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

        // If the window lives on another Mission Control desktop/Space,
        // normal app activation can leave the user on the current desktop.
        // Jump to the window's Space first (best-effort private SkyLight API),
        // then activate/raise/focus the exact AX window.
        if let windowID = DesktopSpaceSwitcher.windowID(for: match.window) {
            DesktopSpaceSwitcher.switchToSpace(containingWindowID: windowID)
        }

        _ = app.unhide()
        _ = AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
            NSLog("[Clanker] AppleScript focus error: %@", error)
            #endif
            return false
        }
        return result.stringValue != "false"
    }
}

// MARK: - Desktop / Space switching

/// Best-effort bridge for Mission Control Spaces.
///
/// AppKit and Accessibility can activate an app and raise a window, but if the
/// target window is on another desktop, macOS often keeps the user on the
/// current desktop unless the global "switch to a Space with open windows" pref
/// happens to be enabled. SkyLight exposes the missing primitive: given a
/// window number, find its owning Space and make that Space current.
///
/// All symbols are loaded with `dlsym` so this remains a graceful no-op if a
/// future macOS build moves/removes the private functions.
fileprivate enum DesktopSpaceSwitcher {
    typealias CGSConnectionID = Int32
    typealias SpaceID = UInt64

    private typealias CGSMainConnectionIDFunc = @convention(c) () -> CGSConnectionID
    private typealias CGSCopySpacesForWindowsFunc = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CGSCopyManagedDisplaySpacesFunc = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias CGSManagedDisplaySetCurrentSpaceFunc = @convention(c) (CGSConnectionID, CFString, SpaceID) -> CGError
    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static func windowID(for window: AXUIElement) -> CGWindowID? {
        for attribute in ["AXWindowNumber", "_AXWindowNumber"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
               let number = value as? NSNumber {
                return CGWindowID(number.uint32Value)
            }
        }

        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        let getWindow = unsafeBitCast(symbol, to: AXUIElementGetWindowFunc.self)
        var windowID = CGWindowID(0)
        guard getWindow(window, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    @discardableResult
    static func switchToSpace(containingWindowID windowID: CGWindowID) -> Bool {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(skyLight) }

        guard let mainConnectionSymbol = dlsym(skyLight, "CGSMainConnectionID"),
              let spacesForWindowsSymbol = dlsym(skyLight, "CGSCopySpacesForWindows"),
              let managedDisplaySpacesSymbol = dlsym(skyLight, "CGSCopyManagedDisplaySpaces"),
              let setCurrentSpaceSymbol = dlsym(skyLight, "CGSManagedDisplaySetCurrentSpace") else {
            return false
        }

        let mainConnectionID = unsafeBitCast(mainConnectionSymbol, to: CGSMainConnectionIDFunc.self)
        let copySpacesForWindows = unsafeBitCast(spacesForWindowsSymbol, to: CGSCopySpacesForWindowsFunc.self)
        let copyManagedDisplaySpaces = unsafeBitCast(managedDisplaySpacesSymbol, to: CGSCopyManagedDisplaySpacesFunc.self)
        let setCurrentSpace = unsafeBitCast(setCurrentSpaceSymbol, to: CGSManagedDisplaySetCurrentSpaceFunc.self)

        let connection = mainConnectionID()
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        // 7 = all spaces. Public constants don't exist for this private API.
        guard let spacesRef = copySpacesForWindows(connection, 7, windowIDs),
              let spaceNumber = (spacesRef.takeRetainedValue() as? [NSNumber])?.first else {
            return false
        }
        let targetSpaceID = spaceNumber.uint64Value

        guard let displaysRef = copyManagedDisplaySpaces(connection),
              let displays = displaysRef.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        for display in displays {
            guard let displayID = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else {
                continue
            }

            let ownsTargetSpace = spaces.contains { space in
                if let id = space["id64"] as? NSNumber {
                    return id.uint64Value == targetSpaceID
                }
                if let id = space["ManagedSpaceID"] as? NSNumber {
                    return id.uint64Value == targetSpaceID
                }
                return false
            }

            if ownsTargetSpace {
                return setCurrentSpace(connection, displayID as CFString, targetSpaceID) == .success
            }
        }

        return false
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
