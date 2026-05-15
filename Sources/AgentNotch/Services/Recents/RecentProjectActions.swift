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

    /// Open a new Ghostty window with `--working-directory=<path>`.
    ///
    /// Per Ghostty's own docs (`ghostty --help`): on macOS the supported
    /// invocation is `open -na Ghostty.app --args --foo=bar`. The `-n` is
    /// load-bearing — without it `open` just brings the existing instance
    /// forward without picking up our `--working-directory` arg.
    private static func openGhostty(at path: String) -> Bool {
        let bundleID = "com.mitchellh.ghostty"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // Fall back to opening the folder in Finder rather than silently
            // failing — at least the user lands in the right place.
            return openFinder(at: path)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true     // mirrors `open -n`
        config.activates = true
        config.arguments = ["--working-directory=\(path)"]

        // We use the async API but don't need the completion — fire-and-forget
        // is fine here since the user's only feedback is the new window
        // showing up.
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        return true
    }

    private static func openFinder(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return NSWorkspace.shared.open(url)
    }
}
