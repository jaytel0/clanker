import AppKit
import Foundation

/// Terminal apps Clanker knows how to discover, focus, or launch.
///
/// macOS does not expose a reliable system-wide "default terminal" setting,
/// so Clanker keeps its own preferred terminal and falls back through this
/// registry when that preference is missing or no longer installed.
enum TerminalApp: CaseIterable, Identifiable, Equatable {
    case terminal, iterm, ghostty, warp, wezterm, kitty, alacritty

    var id: String { bundleID }

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .wezterm: "WezTerm"
        case .kitty: "Kitty"
        case .alacritty: "Alacritty"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var isInstalled: Bool {
        appURL != nil
    }

    /// Preferred ordering for a first-run automatic choice. Ghostty stays first
    /// to preserve Clanker's existing behavior for current users; Terminal.app
    /// is always available as the safe final fallback.
    static let selectionOrder: [TerminalApp] = [
        .ghostty,
        .iterm,
        .warp,
        .wezterm,
        .kitty,
        .alacritty,
        .terminal
    ]

    static var installedForSelection: [TerminalApp] {
        let installed = selectionOrder.filter { $0 == .terminal || $0.isInstalled }
        return installed.isEmpty ? [.terminal] : installed
    }

    static var automaticDefault: TerminalApp {
        installedForSelection.first ?? .terminal
    }

    static func resolving(bundleID: String?) -> TerminalApp {
        guard let bundleID,
              let app = app(withBundleID: bundleID),
              app == .terminal || app.isInstalled else {
            return automaticDefault
        }
        return app
    }

    static func app(withBundleID bundleID: String) -> TerminalApp? {
        allCases.first { $0.bundleID == bundleID }
    }

    static func match(_ displayName: String) -> TerminalApp? {
        switch displayName {
        case "Terminal": .terminal
        case "iTerm", "iTerm2": .iterm
        case "Ghostty": .ghostty
        case "Warp": .warp
        case "WezTerm": .wezterm
        case "Kitty": .kitty
        case "Alacritty": .alacritty
        default: nil
        }
    }
}
