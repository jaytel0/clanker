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
    }

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultRoots = [
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer/personal"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer/shopify")
        ]
        self.roots = (defaults.array(forKey: Key.roots) as? [String]) ?? defaultRoots

        self.cdHookEnabled = defaults.bool(forKey: Key.cdHookEnabled)
    }
}
