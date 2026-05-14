import AppKit
import SwiftUI

/// A non-activating panel that floats above the menu bar across all spaces.
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
        ignoresMouseEvents = false
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that only intercepts mouse events when the click lands inside
/// the SwiftUI content's reported "interactive" region. Anywhere else the
/// click falls through to whatever is behind the panel — the menu bar,
/// desktop, or another window.
///
/// We treat the entire bounds as opaque to mouse events when the notch is
/// expanded (so scroll gestures, hover-tracking and click work everywhere
/// inside the panel) and only the centered notch silhouette when it's closed.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var hitTestProvider: (NSPoint) -> Bool = { _ in true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestProvider(point) else { return nil }
        return super.hitTest(point)
    }

    /// Critical for non-activating panels: without this the very first click
    /// on a SwiftUI control is swallowed activating the panel rather than
    /// dispatching to the control. Returning true means we accept the first
    /// mouse-down even when the window isn't key, so Buttons fire on the
    /// initial click instead of needing two.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
