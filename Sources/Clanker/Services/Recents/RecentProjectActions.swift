import AppKit
import Foundation

/// The three things you can do with a recent project from the notch.
@MainActor
enum RecentProjectAction {
    case ghostty
    case finder
    case github
}

/// Routes a `RecentProjectAction` to the corresponding macOS surface.
@MainActor
enum RecentProjectActions {
    @discardableResult
    static func perform(_ action: RecentProjectAction, project: RecentProject) -> Bool {
        switch action {
        case .ghostty:
            return openGhostty(at: project.path)
        case .finder:
            return openFinder(at: project.path)
        case .github:
            guard let url = project.githubURL else { return false }
            return NSWorkspace.shared.open(url)
        }
    }

    /// Open a new Ghostty window at the given path.
    ///
    /// Uses `ghostty +new-window --working-directory=<path>` via the CLI
    /// embedded in Ghostty.app. This opens a new window inside the *existing*
    /// Ghostty instance (no duplicate dock icons). If Ghostty isn't running,
    /// the CLI will launch it automatically.
    private static func openGhostty(at path: String) -> Bool {
        let bundleID = "com.mitchellh.ghostty"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return openFinder(at: path)
        }

        // The CLI lives inside the app bundle.
        let cliPath = appURL.appendingPathComponent("Contents/MacOS/ghostty").path
        if FileManager.default.fileExists(atPath: cliPath) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cliPath)
            task.arguments = ["+new-window", "--working-directory=\(path)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                // Bring Ghostty to front since the CLI doesn't always activate.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSWorkspace.shared.openApplication(
                        at: appURL,
                        configuration: {
                            let c = NSWorkspace.OpenConfiguration()
                            c.activates = true
                            return c
                        }()
                    ) { _, _ in }
                }
                return true
            } catch {
                // Fall through to legacy path.
            }
        }

        // Fallback: open without -n so we don't spawn duplicate instances.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.arguments = ["--working-directory=\(path)"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        return true
    }

    private static func openFinder(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return NSWorkspace.shared.open(url)
    }
}
