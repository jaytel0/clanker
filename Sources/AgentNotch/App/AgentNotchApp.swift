import AppKit
import SwiftUI

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sessionStore = LocalSessionStore()
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        sessionStore.start()
        showNotch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionStore.stop()
    }

    private func showNotch() {
        guard notchController == nil, let screen = NSScreen.main else { return }
        let viewModel = NotchViewModel(sessionStore: sessionStore)
        let controller = NotchWindowController(screen: screen, viewModel: viewModel)
        controller.showWindow(nil)
        notchController = controller
    }
}
