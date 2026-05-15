import AppKit
import ApplicationServices
import SwiftUI

@main
struct ClankerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(updateManager: appDelegate.updateManager)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sessionStore = LocalSessionStore()
    private lazy var recentsStore = RecentProjectsStore(sessionStore: sessionStore)
    let updateManager = GitHubUpdateManager.shared
    private var notchController: NotchWindowController?
    private var notchViewModel: NotchViewModel?
    private var onboardingController: OnboardingWindowController?
    private var screenObservers: [NSObjectProtocol] = []
    private var screenPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--print-sessions") {
            printSessionsAndTerminate()
            return
        }

        NSApp.setActivationPolicy(.accessory)
        sessionStore.start()
        recentsStore.start()
        updateManager.start()
        requestAccessibilityIfNeeded()

        if RecentsSettings.shared.hasCompletedSetup {
            showNotch()
            installScreenObservers()
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionStore.stop()
        recentsStore.stop()
        screenPollTimer?.invalidate()
        for observer in screenObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func showOnboarding(fromSettings: Bool = false) {
        let controller = OnboardingWindowController()
        controller.onFinish = { [weak self] _ in
            self?.onboardingController = nil
            if !fromSettings {
                self?.showNotch()
                self?.installScreenObservers()
            }
        }
        controller.present()
        onboardingController = controller
    }

    private func showNotch() {
        guard notchController == nil, let screen = NSScreen.main else { return }
        let viewModel = NotchViewModel(
            sessionStore: sessionStore,
            recentsStore: recentsStore,
            updateManager: updateManager
        )
        viewModel.onShowOnboarding = { [weak self] in
            self?.showOnboarding(fromSettings: true)
        }
        notchViewModel = viewModel
        let controller = NotchWindowController(screen: screen, viewModel: viewModel)
        controller.showWindow(nil)
        notchController = controller
    }

    /// Keep the notch glued to the display the user is currently working on.
    ///
    /// Three signals — belt and suspenders since none alone covers every
    /// transition (lid open/close, display hot-plug, app focus jumping to
    /// another monitor):
    ///   * `didChangeScreenParametersNotification` — display added / removed
    ///     / resolution changed.
    ///   * `didActivateApplicationNotification` — user focused an app on a
    ///     different display, so `NSScreen.main` will have flipped.
    ///   * 2s poll — catches the cases where neither notification fires (e.g.
    ///     waking from sleep into a new display arrangement).
    private func installScreenObservers() {
        let nc = NotificationCenter.default
        let workspaceNC = NSWorkspace.shared.notificationCenter

        screenObservers.append(
            nc.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followActiveScreen()
                }
            }
        )

        screenObservers.append(
            workspaceNC.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followActiveScreen()
                }
            }
        )

        screenObservers.append(
            workspaceNC.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followActiveScreen()
                }
            }
        )

        screenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.followActiveScreen()
            }
        }
    }

    private func followActiveScreen() {
        guard let controller = notchController, let screen = NSScreen.main else { return }
        controller.moveToScreen(screen)
    }

    /// Ask for Accessibility permission at launch so the first precise focus
    /// attempt is usually ready. The focus service also re-prompts if trust is
    /// later reset or the user switches to a newly signed build.
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func printSessionsAndTerminate() {
        Task.detached(priority: .utility) {
            let sessions = await LocalSessionScanner.scan()
            await MainActor.run {
                for session in sessions {
                    print([
                        session.harness.rawValue,
                        session.status.rawValue,
                        session.title,
                        "pid=\(session.pid.map(String.init) ?? "-")",
                        "tty=\(session.tty ?? "-")",
                        "live=\(session.isLive)",
                        "cwd=\(session.cwd)"
                    ].joined(separator: " | "))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
