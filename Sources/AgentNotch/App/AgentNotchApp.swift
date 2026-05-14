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
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        sessionStore.start()
        installStatusItem()
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "AN"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Notch", action: #selector(showNotchFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Agent Notch", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showNotchFromMenu() {
        showNotch()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
