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
    private static var lastAccessibilityPromptAt: Date?

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
            if let tty = session.tty, let focusedWindow = focusTerminalApp(tty: tty) {
                focusSelectedWindow(bundleID: TerminalApp.terminal.bundleID, focusedWindow: focusedWindow)
                return true
            }
            return activate(bundleID: TerminalApp.terminal.bundleID)

        case .iterm:
            if let tty = session.tty, let focusedWindow = focusITerm(tty: tty) {
                focusSelectedWindow(bundleID: TerminalApp.iterm.bundleID, focusedWindow: focusedWindow)
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
            return activate(app)
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
            return activate(running)
        }
        return false
    }

    private static func activate(_ app: NSRunningApplication) -> Bool {
        _ = app.unhide()
        return app.activate(options: [.activateAllWindows])
    }

    // MARK: - Accessibility focus

    private struct FocusedWindow {
        var windowID: CGWindowID?
    }

    private struct AXWindowMatch {
        var window: AXUIElement
        var windowID: CGWindowID?
        var score: Int
        var identityScore: Int
    }

    private struct WindowServerMatch {
        var windowID: CGWindowID
        var score: Int
        var isOnCurrentSpace: Bool
    }

    private static func focusSelectedWindow(bundleID: String, focusedWindow: FocusedWindow) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return
        }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)

        var switchedSpace = false
        if let windowID = focusedWindow.windowID {
            switchedSpace = DesktopSpaceSwitcher.switchToSpace(containingWindowID: windowID)
        }

        let window = focusedWindow.windowID.flatMap { axWindow(withID: $0, in: applicationElement) }
            ?? frontWindow(in: applicationElement)

        var resolvedWindowID = focusedWindow.windowID
        if !switchedSpace, let windowID = window.flatMap(DesktopSpaceSwitcher.windowID(for:)) {
            resolvedWindowID = windowID
            DesktopSpaceSwitcher.switchToSpace(containingWindowID: windowID)
        }

        focus(app: app, applicationElement: applicationElement, window: window)
        refocusAfterSpaceSwitch(processIdentifier: app.processIdentifier, windowID: resolvedWindowID)
    }

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
            return focusWindowServerMatch(app: app, session: session)
        }

        let matches = windows.compactMap { window -> AXWindowMatch? in
            let title = stringAttribute(kAXTitleAttribute, from: window) ?? ""
            let document = stringAttribute(kAXDocumentAttribute, from: window)
            let identityScore = scoreWindowContent(window, session: session)
            let score = scoreWindow(title: title, document: document, session: session) + identityScore
            guard score > 0 else { return nil }
            return AXWindowMatch(
                window: window,
                windowID: windowID(for: window),
                score: score,
                identityScore: identityScore
            )
        }
        .sorted { $0.score > $1.score }

        if let match = matches.first(where: { $0.identityScore > 0 }) {
            focusAXMatch(match, app: app, applicationElement: applicationElement)
            return true
        }

        // Ghostty only exposes AX windows for the current Space. If the target
        // session is on another desktop, use WindowServer metadata to jump to
        // the best matching off-Space window first; after the jump, AX can see
        // and raise it normally.
        if let windowServerMatch = bestWindowServerMatch(for: app, session: session),
           !windowServerMatch.isOnCurrentSpace,
           windowServerMatch.score >= 60 {
            return focusWindowServerMatch(
                windowServerMatch,
                app: app,
                applicationElement: applicationElement
            )
        }

        guard let match = matches.first else {
            return focusWindowServerMatch(app: app, session: session)
        }

        focusAXMatch(match, app: app, applicationElement: applicationElement)
        return true
    }

    private static func focusAXMatch(
        _ match: AXWindowMatch,
        app: NSRunningApplication,
        applicationElement: AXUIElement
    ) {
        // If the window lives on another Mission Control desktop/Space,
        // normal app activation can leave the user on the current desktop.
        // Jump to the window's Space first (best-effort private SkyLight API),
        // then activate/raise/focus the exact AX window.
        if let windowID = match.windowID {
            DesktopSpaceSwitcher.switchToSpace(containingWindowID: windowID)
        }

        focus(app: app, applicationElement: applicationElement, window: match.window)
        refocusAfterSpaceSwitch(processIdentifier: app.processIdentifier, windowID: match.windowID)
    }

    private static func focusWindowServerMatch(app: NSRunningApplication, session: AgentSession) -> Bool {
        guard let match = bestWindowServerMatch(for: app, session: session) else {
            return false
        }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusWindowServerMatch(match, app: app, applicationElement: applicationElement)
    }

    private static func focusWindowServerMatch(
        _ match: WindowServerMatch,
        app: NSRunningApplication,
        applicationElement: AXUIElement
    ) -> Bool {
        _ = DesktopSpaceSwitcher.switchToSpace(containingWindowID: match.windowID)
        let window = axWindow(withID: match.windowID, in: applicationElement)
            ?? frontWindow(in: applicationElement)
        focus(app: app, applicationElement: applicationElement, window: window)
        refocusAfterSpaceSwitch(processIdentifier: app.processIdentifier, windowID: match.windowID)
        return true
    }

    private static func focus(app: NSRunningApplication, applicationElement: AXUIElement, window: AXUIElement?) {
        _ = activate(app)
        _ = AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        guard let window else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func refocusAfterSpaceSwitch(processIdentifier: pid_t, windowID: CGWindowID?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task { @MainActor in
                guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
                let applicationElement = AXUIElementCreateApplication(processIdentifier)
                let window = windowID.flatMap { axWindow(withID: $0, in: applicationElement) }
                    ?? frontWindow(in: applicationElement)
                focus(app: app, applicationElement: applicationElement, window: window)
            }
        }
    }

    private static func frontWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private static func axWindow(withID windowID: CGWindowID, in applicationElement: AXUIElement) -> AXUIElement? {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        return windows.first { window in
            DesktopSpaceSwitcher.windowID(for: window) == windowID
        }
    }

    private static func windowID(for window: AXUIElement) -> CGWindowID? {
        DesktopSpaceSwitcher.windowID(for: window)
    }

    private static func bestWindowServerMatch(
        for app: NSRunningApplication,
        session: AgentSession
    ) -> WindowServerMatch? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windowInfo.compactMap { info -> WindowServerMatch? in
            guard number(info[kCGWindowOwnerPID as String])?.int32Value == app.processIdentifier,
                  number(info[kCGWindowLayer as String])?.intValue == 0,
                  let title = info[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let windowIDNumber = number(info[kCGWindowNumber as String]),
                  isUsableWindowBounds(info[kCGWindowBounds as String]) else {
                return nil
            }

            let score = scoreWindowServerTitle(title, session: session)
            guard score > 0 else { return nil }

            let windowID = CGWindowID(windowIDNumber.uint32Value)
            return WindowServerMatch(
                windowID: windowID,
                score: score,
                isOnCurrentSpace: DesktopSpaceSwitcher.isWindowOnCurrentSpace(windowID) ?? true
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.isOnCurrentSpace != $1.isOnCurrentSpace { return !$0.isOnCurrentSpace }
            return $0.windowID > $1.windowID
        }
        .first
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let int = value as? Int { return NSNumber(value: int) }
        if let int32 = value as? Int32 { return NSNumber(value: int32) }
        if let uint32 = value as? UInt32 { return NSNumber(value: uint32) }
        return nil
    }

    private static func isUsableWindowBounds(_ value: Any?) -> Bool {
        guard let bounds = value as? [String: Any],
              let width = number(bounds["Width"])?.doubleValue,
              let height = number(bounds["Height"])?.doubleValue else {
            return true
        }
        return width >= 120 && height >= 100
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

    private static func scoreWindowServerTitle(_ title: String, session: AgentSession) -> Int {
        let normalizedTitle = title.lowercased()
        let isPiWindow = normalizedTitle.contains("π") || normalizedTitle.contains(" pi")
        let isCodexLikeWindow = containsBrailleSpinner(title)
        let projectBasename = normalizedPath(expandingHomeIn(session.cwd))
            .split(separator: "/")
            .last
            .map(String.init)
            ?? session.projectName.lowercased()

        var score = scoreWindow(title: title, document: nil, session: session)
        if normalizedTitle == session.projectName.lowercased() {
            score += 20
        }
        if !projectBasename.isEmpty, normalizedTitle.contains(projectBasename) {
            score += 20
        }

        switch session.harness {
        case .pi:
            score += isPiWindow ? 80 : -50
        case .codex, .claude:
            if isCodexLikeWindow { score += 45 }
            if isPiWindow { score -= 70 }
        case .terminal:
            if !isPiWindow && !isCodexLikeWindow { score += 15 }
        }

        return score
    }

    private static func scoreWindowContent(_ window: AXUIElement, session: AgentSession) -> Int {
        guard let content = terminalTextContent(in: window)?.lowercased(),
              !content.isEmpty else {
            return 0
        }

        var score = 0
        for value in [session.title, session.preview] {
            let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 8, !isGenericSessionText(normalized, harness: session.harness) else {
                continue
            }
            if content.contains(normalized) {
                score += 300
            }
        }

        let cwd = expandingHomeIn(session.cwd).lowercased()
        if cwd.count >= 8, content.contains(cwd) {
            score += 80
        }
        if let tty = session.tty?.lowercased(), content.contains(tty) {
            score += 120
        }

        return score
    }

    private static func terminalTextContent(in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }

        if stringAttribute(kAXRoleAttribute, from: element) == kAXTextAreaRole,
           let value = stringAttribute(kAXValueAttribute, from: element) {
            return String(value.prefix(20_000))
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let value = terminalTextContent(in: child, depth: depth + 1) {
                return value
            }
        }
        return nil
    }

    private static func containsBrailleSpinner(_ title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            (0x2800...0x28FF).contains(Int(scalar.value))
        }
    }

    private static func isGenericSessionText(_ value: String, harness: HarnessID) -> Bool {
        let generic = [
            "codex",
            "codex session",
            "claude",
            "claude code",
            "claude session",
            "pi",
            "pi session",
            "terminal",
            "shell"
        ]
        return generic.contains(value) || value == harness.displayName.lowercased()
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
        let now = Date()
        if let lastAccessibilityPromptAt,
           now.timeIntervalSince(lastAccessibilityPromptAt) < 60 {
            return false
        }
        lastAccessibilityPromptAt = now

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
    private static func focusTerminalApp(tty: String) -> FocusedWindow? {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t as string) is equal to "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  set index of w to 1
                  return "window:" & (id of w as string)
                end if
              end try
            end repeat
          end repeat
        end tell
        return "false"
        """
        return runFocusAppleScript(source)
    }

    /// Focus the iTerm2 session whose `tty` matches.
    private static func focusITerm(tty: String) -> FocusedWindow? {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s as string) is equal to "\(escaped)" then
                    select s
                    tell t to select
                    tell w to select
                    try
                      return "window:" & (id of w as string)
                    on error
                      return "true"
                    end try
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return "false"
        """
        return runFocusAppleScript(source)
    }

    @discardableResult
    private static func runFocusAppleScript(_ source: String) -> FocusedWindow? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            NSLog("[Clanker] AppleScript focus error: %@", error)
            #endif
            return nil
        }

        guard let value = result.stringValue, value != "false" else {
            return nil
        }
        if value.hasPrefix("window:") {
            let rawID = String(value.dropFirst("window:".count))
            return UInt32(rawID).map { FocusedWindow(windowID: CGWindowID($0)) }
        }
        return FocusedWindow(windowID: nil)
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
        guard let targetSpaceID = spaceIDs(containingWindowID: windowID).first else {
            return false
        }

        return setCurrentSpace(targetSpaceID)
    }

    static func isWindowOnCurrentSpace(_ windowID: CGWindowID) -> Bool? {
        let windowSpaces = Set(spaceIDs(containingWindowID: windowID))
        guard !windowSpaces.isEmpty else { return nil }
        let currentSpaces = currentSpaceIDs()
        guard !currentSpaces.isEmpty else { return nil }
        return !windowSpaces.isDisjoint(with: currentSpaces)
    }

    static func spaceIDs(containingWindowID windowID: CGWindowID) -> [SpaceID] {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return []
        }
        defer { dlclose(skyLight) }

        guard let mainConnectionSymbol = dlsym(skyLight, "CGSMainConnectionID"),
              let spacesForWindowsSymbol = dlsym(skyLight, "CGSCopySpacesForWindows") else {
            return []
        }

        let mainConnectionID = unsafeBitCast(mainConnectionSymbol, to: CGSMainConnectionIDFunc.self)
        let copySpacesForWindows = unsafeBitCast(spacesForWindowsSymbol, to: CGSCopySpacesForWindowsFunc.self)

        let connection = mainConnectionID()
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        // 7 = all spaces. Public constants don't exist for this private API.
        guard let spacesRef = copySpacesForWindows(connection, 7, windowIDs),
              let spaceNumbers = spacesRef.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return spaceNumbers.map(\.uint64Value)
    }

    static func currentSpaceIDs() -> Set<SpaceID> {
        Set(managedDisplaySpaces().compactMap { display in
            guard let currentSpace = display["Current Space"] as? [String: Any] else {
                return nil
            }
            return spaceID(from: currentSpace)
        })
    }

    private static func setCurrentSpace(_ targetSpaceID: SpaceID) -> Bool {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(skyLight) }

        guard let mainConnectionSymbol = dlsym(skyLight, "CGSMainConnectionID"),
              let setCurrentSpaceSymbol = dlsym(skyLight, "CGSManagedDisplaySetCurrentSpace") else {
            return false
        }

        let mainConnectionID = unsafeBitCast(mainConnectionSymbol, to: CGSMainConnectionIDFunc.self)
        let setCurrentSpace = unsafeBitCast(setCurrentSpaceSymbol, to: CGSManagedDisplaySetCurrentSpaceFunc.self)
        let connection = mainConnectionID()

        for display in managedDisplaySpaces() {
            guard let displayID = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else {
                continue
            }

            let ownsTargetSpace = spaces.contains { spaceID(from: $0) == targetSpaceID }
            if ownsTargetSpace {
                return setCurrentSpace(connection, displayID as CFString, targetSpaceID) == .success
            }
        }

        return false
    }

    private static func managedDisplaySpaces() -> [[String: Any]] {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return []
        }
        defer { dlclose(skyLight) }

        guard let mainConnectionSymbol = dlsym(skyLight, "CGSMainConnectionID"),
              let managedDisplaySpacesSymbol = dlsym(skyLight, "CGSCopyManagedDisplaySpaces") else {
            return []
        }

        let mainConnectionID = unsafeBitCast(mainConnectionSymbol, to: CGSMainConnectionIDFunc.self)
        let copyManagedDisplaySpaces = unsafeBitCast(managedDisplaySpacesSymbol, to: CGSCopyManagedDisplaySpacesFunc.self)
        let connection = mainConnectionID()
        guard let displaysRef = copyManagedDisplaySpaces(connection),
              let displays = displaysRef.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return displays
    }

    private static func spaceID(from space: [String: Any]) -> SpaceID? {
        if let id = space["id64"] as? NSNumber {
            return id.uint64Value
        }
        if let id = space["ManagedSpaceID"] as? NSNumber {
            return id.uint64Value
        }
        return nil
    }
}
