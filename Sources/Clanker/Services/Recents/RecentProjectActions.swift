import AppKit
import Foundation

/// The three things you can do with a recent project from the notch.
@MainActor
enum RecentProjectAction {
    case terminal
    case finder
    case github
}

/// Routes a `RecentProjectAction` to the corresponding macOS surface.
@MainActor
enum RecentProjectActions {
    @discardableResult
    static func perform(_ action: RecentProjectAction, project: RecentProject) -> Bool {
        switch action {
        case .terminal:
            return TerminalLauncher.openProject(at: project.path)
        case .finder:
            return openFinder(at: project.path)
        case .github:
            guard let url = project.githubURL else { return false }
            return NSWorkspace.shared.open(url)
        }
    }

    private static func openFinder(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return NSWorkspace.shared.open(url)
    }
}
