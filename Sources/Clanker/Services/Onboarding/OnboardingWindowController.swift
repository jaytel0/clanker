import AppKit
import SwiftUI

/// Hosts the first-run setup UI in a floating, titled panel.
///
/// Call `present()` to show. The window closes itself after the user
/// completes or skips setup; `onFinish` is called with the chosen roots.
@MainActor
final class OnboardingWindowController: NSWindowController {
    var onFinish: (([String]) -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        // Rounded window corners
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true

        super.init(window: panel)

        let view = OnboardingView { [weak self] selectedPaths in
            self?.finish(roots: selectedPaths)
        }
        panel.contentView = NSHostingView(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(roots: [String]) {
        let settings = RecentsSettings.shared
        if !roots.isEmpty {
            settings.roots = roots
        }
        settings.hasCompletedSetup = true
        onFinish?(roots)
        close()
    }
}
