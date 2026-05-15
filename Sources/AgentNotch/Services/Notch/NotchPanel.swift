import AppKit
import SwiftUI

/// A non-activating panel that floats above the menu bar across all spaces.
///
/// Default to `ignoresMouseEvents = true` so the panel is invisible to the
/// WindowServer's click routing while the notch is closed — every click /
/// scroll / hover passes straight through to the app below. The controller
/// flips this off only while the notch is expanded so SwiftUI controls inside
/// the opened panel receive events normally. This matches the Ping Island
/// design (`PingIsland/UI/Window/NotchWindow.swift`) and is the only way to
/// get true OS-level click-through; view-level `hitTest:` tricks suppress
/// only intra-window dispatch and still leave the panel owning the click at
/// the WindowServer layer.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        acceptsMouseMovedEvents = false
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Click-through fallback for the brief windows when `ignoresMouseEvents`
    /// is `false` (notch open) but the user happens to click in a transparent
    /// corner of the panel rect that no SwiftUI view claims.
    ///
    /// Without this, those clicks are silently swallowed. Re-posting them as
    /// a CGEvent at the same screen location lets the app below receive the
    /// click. Lifted from Ping Island's `NotchPanel.sendEvent`.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let contentView, contentView.hitTest(event.locationInWindow) == nil {
                // No view in our panel wants this event; bounce it to
                // whatever window is below by re-posting as a CGEvent at
                // the same screen location.
                let screenLocation = convertPoint(toScreen: event.locationInWindow)
                DispatchQueue.main.async { [weak self] in
                    self?.repostMouseDown(event, screenLocation: screenLocation)
                }
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func repostMouseDown(_ event: NSEvent, screenLocation: NSPoint) {
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
        // Convert AppKit screen coords (origin bottom-left) to Quartz screen
        // coords (origin top-left) for CGEvent.
        let cgPoint = CGPoint(x: screenLocation.x, y: mainScreenHeight - screenLocation.y)

        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown; mouseButton = .left
        case .rightMouseDown: mouseType = .rightMouseDown; mouseButton = .right
        case .otherMouseDown: mouseType = .otherMouseDown; mouseButton = .center
        default: return
        }
        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}

/// Hosting view for the notch's SwiftUI tree. Returning `nil` from `hitTest:`
/// for points outside the painted shape stops SwiftUI from reacting to clicks
/// in the transparent rounded-corner regions of the panel rect, and also
/// causes `NotchPanel.sendEvent` to bounce those clicks to the app below.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var hitTestProvider: (NSPoint) -> Bool = { _ in true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestProvider(point) else { return nil }
        return super.hitTest(point)
    }

    /// Critical for non-activating panels: without this the very first click
    /// on a SwiftUI control would just activate the panel rather than
    /// dispatching to the control. Returning true means we accept the first
    /// mouse-down even when the window isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
