import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    private let screen: NSScreen
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, viewModel: NotchViewModel) {
        self.screen = screen
        self.viewModel = viewModel

        let panel = NotchPanel(contentRect: Self.frame(on: screen, expanded: false))
        let content = NotchRootView(viewModel: viewModel)
        panel.contentViewController = NSHostingController(rootView: content)
        super.init(window: panel)

        viewModel.$isExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.resize(expanded: expanded)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func resize(expanded: Bool) {
        guard let window else { return }
        window.setFrame(Self.frame(on: screen, expanded: expanded), display: true, animate: true)
        if expanded {
            window.makeKey()
        }
    }

    private static func frame(on screen: NSScreen, expanded: Bool) -> NSRect {
        let width: CGFloat = expanded ? 560 : 268
        let height: CGFloat = expanded ? 360 : 36
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }
}
