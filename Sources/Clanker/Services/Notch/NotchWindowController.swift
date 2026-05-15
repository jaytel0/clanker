import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    /// Closed-state notch dimensions.
    ///
    /// On a notched MacBook display, the closed bar must be wide enough to
    /// span past the hardware notch (~230pt) so harness icons sit clear of
    /// the silhouette. On non-notch displays (Studio Display, externals) we
    /// can be much narrower — just enough for icons + badge.
    static let closedWidthNotched: CGFloat = 310
    static let closedWidthFlat: CGFloat = 230
    static let closedHeight: CGFloat = 32

    static func closedWidth(for screen: NSScreen) -> CGFloat {
        screen.hasNotch ? closedWidthNotched : closedWidthFlat
    }

    /// Expanded-state notch dimensions.
    static let expandedWidth: CGFloat = 660
    static let expandedHeight: CGFloat = 380

    // Shared corner radii. Used by NotchRootView for rendering and by the
    // hit-test path in NotchWindowController.notchShapeContains — keep in
    // lockstep with the painted silhouette.
    static let closedTopRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 26

    private(set) var screen: NSScreen
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: GlobalNotchEventMonitor?

    init(screen: NSScreen, viewModel: NotchViewModel) {
        self.screen = screen
        self.viewModel = viewModel
        viewModel.screenHasNotch = screen.hasNotch

        // The panel is ALWAYS sized to the expanded footprint and anchored to
        // the very top of the screen. The closed silhouette is just a smaller
        // shape painted inside the same transparent canvas. The panel itself
        // never resizes — that resize was the source of the open↔close
        // flicker, because the panel frame jumped instantly while SwiftUI
        // animated content with a spring.
        //
        // True click-through is provided by `NotchPanel.ignoresMouseEvents`,
        // which the controller flips based on `isExpanded`:
        //   * closed   → true  — every event passes straight through to the
        //                        app below
        //   * expanded → false — events flow into SwiftUI so buttons work
        //
        // Hover/click detection while closed is driven by
        // `GlobalNotchEventMonitor`, which uses `NSEvent.mouseLocation` and a
        // global event monitor (since `ignoresMouseEvents = true` means the
        // panel itself sees nothing).
        let frame = Self.panelFrame(on: screen)
        let panel = NotchPanel(contentRect: frame)

        let rootView = NotchRootView(viewModel: viewModel)
        let hostingView = NotchHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]

        // When the notch is expanded and ignoresMouseEvents is off, this
        // filter ensures clicks in the panel's transparent corners get
        // bounced through `NotchPanel.sendEvent` to the app below rather
        // than being silently swallowed by SwiftUI's empty background.
        hostingView.hitTestProvider = { [weak viewModel] point in
            guard let viewModel else { return false }
            return Self.notchShapeContains(point, isExpanded: viewModel.isExpanded)
        }

        let controller = NSViewController()
        controller.view = hostingView
        panel.contentViewController = controller

        super.init(window: panel)

        // Toggle mouse-event handling with state.
        viewModel.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak panel, weak hostingView] isExpanded in
                guard let panel else { return }
                panel.ignoresMouseEvents = !isExpanded
                hostingView?.window?.invalidateShadow()
                if isExpanded {
                    // Surface the panel so it can take key for keyboard
                    // affordances inside the opened notch (esc to close,
                    // arrow keys to navigate rows, etc.).
                    panel.makeKey()
                }
            }
            .store(in: &cancellables)

        let monitor = GlobalNotchEventMonitor(viewModel: viewModel, window: panel)
        monitor.start()
        self.globalMonitor = monitor
    }

    /// Window controllers live for the entire app lifetime in this app, so we
    /// don't bother tearing down the monitor in deinit — the OS reclaims it
    /// at process exit.
    required init?(coder: NSCoder) { nil }

    private static func panelFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - expandedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
    }

    /// Reposition the panel onto the given screen. Cheap and idempotent —
    /// safe to call from screen-change notifications without guarding.
    func moveToScreen(_ newScreen: NSScreen) {
        guard let panel = window else { return }
        let frame = Self.panelFrame(on: newScreen)
        // No animation — jumping displays should feel instant, not draggy.
        if newScreen !== screen || panel.frame != frame {
            self.screen = newScreen
            viewModel.screenHasNotch = newScreen.hasNotch
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    /// True when `point` (panel-local, AppKit origin bottom-left) lies inside
    /// the painted notch silhouette for the given state.
    ///
    /// The painted shape is horizontally centered in the panel and pinned to
    /// the panel's top edge — so the shape rect's origin in panel-local
    /// coordinates is `((panelWidth - shapeWidth)/2, panelHeight - shapeHeight)`.
    static func notchShapeContains(_ point: NSPoint, isExpanded: Bool, closedWidth: CGFloat? = nil) -> Bool {
        let cw = closedWidth ?? closedWidthNotched
        let shapeWidth = isExpanded ? expandedWidth : cw
        let shapeHeight = isExpanded ? expandedHeight : closedHeight
        let topRadius = isExpanded ? expandedTopRadius : closedTopRadius
        let bottomRadius = isExpanded ? expandedBottomRadius : closedBottomRadius

        let originX = (expandedWidth - shapeWidth) / 2
        let originY = expandedHeight - shapeHeight

        // Panel-local → shape-local, then flip Y because the shape's path
        // uses top-origin coordinates while AppKit windows use bottom-origin.
        let localX = point.x - originX
        let localY = shapeHeight - (point.y - originY)

        guard localX >= 0, localX <= shapeWidth,
              localY >= 0, localY <= shapeHeight else {
            return false
        }

        let path = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .path(in: CGRect(x: 0, y: 0, width: shapeWidth, height: shapeHeight))
        return path.contains(CGPoint(x: localX, y: localY))
    }
}
