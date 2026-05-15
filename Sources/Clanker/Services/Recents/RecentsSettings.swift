import Combine
import Foundation

/// User preferences for the Recent Projects feature.
///
/// Persisted in `UserDefaults` so changes survive relaunches. All fields are
/// `@Published` so SwiftUI views and the `RecentProjectsStore` can react to
/// edits without manual notification plumbing.
@MainActor
final class RecentsSettings: ObservableObject {
    static let shared = RecentsSettings()

    private enum Key {
        static let roots = "recents.roots"
        static let cdHookEnabled = "recents.cdHookEnabled"
        static let defaultRootsVersion = "recents.defaultRootsVersion"
        static let hasCompletedSetup = "recents.hasCompletedSetup"
    }

    private static let currentDefaultRootsVersion = 1

    /// Folders we walk for repos. Each direct child containing a `.git` entry
    /// is treated as a repo; the basename of the root becomes its category.
    @Published var roots: [String] {
        didSet { defaults.set(roots, forKey: Key.roots) }
    }

    /// Mirror of "is the chpwd hook installed in `.zshrc`". Persisted purely
    /// as a UI hint; `CdHookInstaller.isInstalled()` is the source of truth
    /// when actually deciding whether to read the log.
    @Published var cdHookEnabled: Bool {
        didSet { defaults.set(cdHookEnabled, forKey: Key.cdHookEnabled) }
    }

    /// `true` once the user has finished the first-run setup flow.
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultRoots = Self.defaultRoots()
        var roots = (defaults.array(forKey: Key.roots) as? [String]) ?? defaultRoots
        if defaults.integer(forKey: Key.defaultRootsVersion) < Self.currentDefaultRootsVersion {
            roots = Self.appendingMissingRoots(
                [
                    (NSHomeDirectory() as NSString).appendingPathComponent("Developer/tries")
                ],
                to: roots
            )
            defaults.set(roots, forKey: Key.roots)
            defaults.set(Self.currentDefaultRootsVersion, forKey: Key.defaultRootsVersion)
        }
        self.roots = roots

        self.cdHookEnabled = defaults.bool(forKey: Key.cdHookEnabled)
        self.hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
    }

    private static func defaultRoots() -> [String] {
        [
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer/personal"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer/shopify"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer/tries")
        ]
    }

    private static func appendingMissingRoots(_ additions: [String], to roots: [String]) -> [String] {
        var result = roots
        let existing = Set(roots.map(normalizedPath))
        for root in additions where !existing.contains(normalizedPath(root)) {
            result.append(root)
        }
        return result
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
