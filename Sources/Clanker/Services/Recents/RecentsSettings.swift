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
        static let preferredTerminalBundleID = "recents.preferredTerminalBundleID"
    }

    private static let currentDefaultRootsVersion = 2

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

    /// Bundle identifier for the terminal used when opening recent projects.
    /// Nil means "auto" — choose the first installed terminal in Clanker's
    /// registry, falling back to Terminal.app.
    @Published var preferredTerminalBundleID: String? {
        didSet {
            if let preferredTerminalBundleID {
                defaults.set(preferredTerminalBundleID, forKey: Key.preferredTerminalBundleID)
            } else {
                defaults.removeObject(forKey: Key.preferredTerminalBundleID)
            }
        }
    }

    var preferredTerminalApp: TerminalApp {
        get { TerminalApp.resolving(bundleID: preferredTerminalBundleID) }
        set { preferredTerminalBundleID = newValue.bundleID }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
        let storedRoots = defaults.array(forKey: Key.roots) as? [String]
        var roots = storedRoots ?? Self.defaultRoots()
        if !hasCompletedSetup,
           defaults.integer(forKey: Key.defaultRootsVersion) < Self.currentDefaultRootsVersion {
            roots = Self.defaultRoots()
        }
        defaults.set(roots, forKey: Key.roots)
        defaults.set(Self.currentDefaultRootsVersion, forKey: Key.defaultRootsVersion)
        self.roots = roots

        self.cdHookEnabled = defaults.bool(forKey: Key.cdHookEnabled)
        self.hasCompletedSetup = hasCompletedSetup
        self.preferredTerminalBundleID = defaults.string(forKey: Key.preferredTerminalBundleID)
    }

    private static func defaultRoots() -> [String] {
        let developerDir = normalizedPath(
            (NSHomeDirectory() as NSString).appendingPathComponent("Developer")
        )
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: developerDir, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        return [developerDir]
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
