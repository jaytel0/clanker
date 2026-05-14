import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    /// Maximum panel canvas. The notch silhouette animates inside this canvas
    /// in pure SwiftUI — the AppKit window itself never resizes, which is what
    /// makes the morph buttery smooth.
    static let canvasWidth: CGFloat = 620
    static let canvasHeight: CGFloat = 460

    /// Closed-state notch dimensions.
    static let closedWidth: CGFloat = 248
    static let closedHeight: CGFloat = 32

    /// Expanded-state notch dimensions.
    static let expandedWidth: CGFloat = 580
    static let expandedHeight: CGFloat = 380

    private let screen: NSScreen
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, viewModel: NotchViewModel) {
        self.screen = screen
        self.viewModel = viewModel

        let frame = Self.canvasFrame(on: screen)
        let panel = NotchPanel(contentRect: frame)

        let rootView = NotchRootView(viewModel: viewModel)
        let hostingView = NotchHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]

        // Hit-test only the visible notch silhouette so menu-bar clicks pass
        // through everywhere else.
        hostingView.hitTestProvider = { [weak viewModel] point in
            guard let viewModel else { return false }
            let canvasSize = NSSize(width: Self.canvasWidth, height: Self.canvasHeight)
            let interactiveSize = viewModel.isExpanded
                ? NSSize(width: Self.expandedWidth, height: Self.expandedHeight)
                : NSSize(width: Self.closedWidth, height: Self.closedHeight)
            // The notch sits flush with the top of the canvas, horizontally
            // centered. AppKit windows are bottom-up so "top" is maxY.
            let originX = (canvasSize.width - interactiveSize.width) / 2
            let originY = canvasSize.height - interactiveSize.height
            let interactiveRect = NSRect(
                x: originX,
                y: originY,
                width: interactiveSize.width,
                height: interactiveSize.height
            )
            return interactiveRect.contains(point)
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
    }

    required init?(coder: NSCoder) { nil }

    private static func canvasFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - canvasWidth / 2,
            y: screen.frame.maxY - canvasHeight,
            width: canvasWidth,
            height: canvasHeight
        )
    }
}
