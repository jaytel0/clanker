import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    /// Maximum panel canvas. The notch silhouette animates inside this canvas
    /// in pure SwiftUI — the AppKit window itself never resizes, which is what
    /// makes the morph buttery smooth.
    static let canvasWidth: CGFloat = 740
    static let canvasHeight: CGFloat = 460

    /// Closed-state notch dimensions.
    ///
    /// The physical MacBook notch is ~230 pt wide. We extend ~70 pt past it on
    /// each side so the harness icons and attention badge sit clear of the
    /// hardware silhouette instead of being eclipsed by it.
    static let closedWidth: CGFloat = 372
    static let closedHeight: CGFloat = 32

    /// Expanded-state notch dimensions.
    static let expandedWidth: CGFloat = 660
    static let expandedHeight: CGFloat = 380

    // Shared corner radii. Used by NotchRootView for rendering and by the
    // hit-test path below — keep them in lockstep so clicks land on exactly
    // the visible silhouette.
    static let closedTopRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 26

    private let screen: NSScreen
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?

    init(screen: NSScreen, viewModel: NotchViewModel) {
        self.screen = screen
        self.viewModel = viewModel

        let frame = Self.canvasFrame(on: screen)
        let panel = NotchPanel(contentRect: frame)

        let rootView = NotchRootView(viewModel: viewModel)
        let hostingView = NotchHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]

        // Hit-test against the *actual visible notch silhouette*. Anything
        // outside the curved shape — the corners of the bounding rect, the
        // empty space below the closed pill, the menu bar to either side —
        // returns nil so the click falls through to the menu bar / window
        // beneath us. Without this the rectangular bounding box would silently
        // eat clicks in regions where there's no UI painted at all.
        hostingView.hitTestProvider = { [weak viewModel] point in
            guard let viewModel else { return false }
            return Self.notchShapeContains(point, isExpanded: viewModel.isExpanded)
        }

        let controller = NSViewController()
        controller.view = hostingView
        panel.contentViewController = controller

        super.init(window: panel)

        viewModel.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                hostingView.window?.invalidateShadow()
            }
            .store(in: &cancellables)

        installGlobalClickMonitor()
    }

    /// Window controllers live for the entire app lifetime in this app, so we
    /// don't bother tearing down the monitor in deinit — the OS reclaims it
    /// at process exit. (Swift 6 strict concurrency forbids touching
    /// non-Sendable stored properties from a nonisolated deinit anyway.)

    required init?(coder: NSCoder) { nil }

    /// Collapse the notch the moment the user clicks anywhere outside our app.
    ///
    /// `addGlobalMonitorForEvents` only delivers events that were dispatched
    /// to *other* applications, so a click landing on our visible silhouette
    /// does not fire this monitor (it stays expanded as the user interacts).
    /// Any click in the menu bar, dock, browser, etc. simultaneously reaches
    /// its target app *and* dismisses the notch — if the notch happened to
    /// have expanded by accident, it's gone before the user notices.
    private func installGlobalClickMonitor() {
        let viewModel = self.viewModel
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in
                viewModel.collapse()
            }
        }
    }

    private static func canvasFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - canvasWidth / 2,
            y: screen.frame.maxY - canvasHeight,
            width: canvasWidth,
            height: canvasHeight
        )
    }

    /// Returns `true` only when `point` (in AppKit window-local coordinates,
    /// origin at bottom-left) lies inside the painted notch shape for the
    /// given expand state.
    static func notchShapeContains(_ point: NSPoint, isExpanded: Bool) -> Bool {
        let shapeWidth = isExpanded ? expandedWidth : closedWidth
        let shapeHeight = isExpanded ? expandedHeight : closedHeight
        let topRadius = isExpanded ? expandedTopRadius : closedTopRadius
        let bottomRadius = isExpanded ? expandedBottomRadius : closedBottomRadius

        // Shape is centered horizontally and pinned to the top of the canvas.
        let originX = (canvasWidth - shapeWidth) / 2

        // Flip Y: AppKit window y=0 is bottom; the shape's path uses y=0 at
        // the top.
        let localX = point.x - originX
        let localY = canvasHeight - point.y

        // Cheap bounding-box reject before the path containment check.
        guard localX >= 0, localX <= shapeWidth,
              localY >= 0, localY <= shapeHeight else {
            return false
        }

        let path = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .path(in: CGRect(x: 0, y: 0, width: shapeWidth, height: shapeHeight))
        return path.contains(CGPoint(x: localX, y: localY))
    }
}
