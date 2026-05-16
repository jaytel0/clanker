import AppKit
import Combine

/// Drives the notch view model from global cursor position instead of SwiftUI
/// `.onHover`.
///
/// We use this approach (lifted from Ping Island's `EventMonitors` +
/// `NotchViewModel.handleMouseMove`) because the panel runs with
/// `ignoresMouseEvents = true` while closed — that's what gives us true
/// WindowServer-level click-through to the apps below — and a window that
/// ignores mouse events also receives no `.onHover` callbacks.
///
/// `NSEvent.addGlobalMonitorForEvents` observes events that go to *other*
/// apps, which covers the closed state. A paired local monitor covers the
/// expanded state when `ignoresMouseEvents` flips off and events are
/// delivered to us.
@MainActor
final class GlobalNotchEventMonitor {
    private weak var viewModel: NotchViewModel?
    private weak var window: NSWindow?

    private var moveMonitor: NSEventMonitorPair?
    private var downMonitor: NSEventMonitorPair?
    private var keyMonitor: Any?
    private var lastMoveDispatch: Date = .distantPast

    /// Throttle global mouseMoved processing. The OS fires these at very high
    /// rates while the cursor is in motion; the view model only cares about
    /// in/out transitions so 50ms granularity is invisible to the user and
    /// keeps idle-while-mousing CPU near zero.
    private static let mouseMoveThrottle: TimeInterval = 0.05

    init(viewModel: NotchViewModel, window: NSWindow) {
        self.viewModel = viewModel
        self.window = window
    }

    func start() {
        stop()
        moveMonitor = NSEventMonitorPair(mask: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }
        moveMonitor?.start()

        downMonitor = NSEventMonitorPair(
            mask: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.handleMouseDown()
        }
        downMonitor?.start()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDown(event) == true {
                return nil
            }
            return event
        }
    }

    func stop() {
        moveMonitor?.stop(); moveMonitor = nil
        downMonitor?.stop(); downMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Handlers

    private func handleMouseMove() {
        let now = Date()
        if now.timeIntervalSince(lastMoveDispatch) < Self.mouseMoveThrottle { return }
        lastMoveDispatch = now

        guard let viewModel, let screen = currentScreen() else { return }
        let location = NSEvent.mouseLocation
        let cw = viewModel.currentClosedWidth
        let inside = NotchHitTest.cursorInsideHoverSurface(
            location,
            screen: screen,
            isExpanded: viewModel.isExpanded,
            closedWidth: cw
        )
        viewModel.setHover(inside)
    }

    private func handleMouseDown() {
        guard let viewModel, let screen = currentScreen() else { return }
        let location = NSEvent.mouseLocation
        let cw = viewModel.currentClosedWidth

        if viewModel.isExpanded {
            // Click outside the opened silhouette → collapse. Clicks inside
            // the shape are already being delivered to SwiftUI normally
            // (ignoresMouseEvents is false while expanded), so buttons fire
            // without any help from us.
            let inside = NotchHitTest.cursorInsideHoverSurface(
                location,
                screen: screen,
                isExpanded: true,
                closedWidth: cw
            )
            if !inside { viewModel.collapse() }
        } else {
            // Click on the closed-notch area → expand. Hover-to-open is the
            // primary path; this just makes a deliberate click feel responsive
            // for users who haven't yet learned the hover gesture.
            let inside = NotchHitTest.cursorInsideHoverSurface(
                location,
                screen: screen,
                isExpanded: false,
                closedWidth: cw
            )
            if inside { viewModel.toggleExpanded() }
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let viewModel,
              let window,
              viewModel.isExpanded,
              window.isKeyWindow,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] else {
            return false
        }
        switch event.charactersIgnoringModifiers {
        case "1":
            viewModel.selectPane(.sessions)
            return true
        case "2":
            viewModel.selectPane(.recents)
            return true
        case "3":
            viewModel.selectPane(.spend)
            return true
        default:
            return false
        }
    }

    private func currentScreen() -> NSScreen? {
        window?.screen ?? NSScreen.main
    }
}

/// Geometry of the closed and expanded notch silhouettes in *screen*
/// coordinates, used for global hit-testing against `NSEvent.mouseLocation`.
@MainActor
enum NotchHitTest {
    /// Slight outward dilation so the cursor entering the boundary triggers
    /// promptly without sub-pixel jitter and so a fast horizontal swipe along
    /// the menu bar still registers when it grazes the closed notch.
    private static let hoverInset: CGFloat = -6

    static func cursorInsideHoverSurface(
        _ location: CGPoint,
        screen: NSScreen,
        isExpanded: Bool,
        closedWidth: CGFloat? = nil
    ) -> Bool {
        shapeRect(on: screen, isExpanded: isExpanded, closedWidth: closedWidth)
            .insetBy(dx: hoverInset, dy: hoverInset)
            .contains(location)
    }

    static func shapeRect(on screen: NSScreen, isExpanded: Bool, closedWidth: CGFloat? = nil) -> CGRect {
        let cw = closedWidth ?? NotchWindowController.closedWidth(for: screen)
        let width: CGFloat = isExpanded
            ? NotchWindowController.expandedWidth
            : cw
        let height: CGFloat = isExpanded
            ? NotchWindowController.expandedHeight
            : NotchWindowController.closedHeight
        let frame = screen.frame
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }
}

/// Pairs a global and local `NSEvent` monitor so we observe events whether
/// they're routed to other apps (global) or to us (local). Calls back on the
/// main actor — Apple delivers `NSEvent` monitor callbacks on the main thread.
@MainActor
final class NSEventMonitorPair {
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [handler] event in
            handler(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [handler] event in
            handler(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
