import AppKit
import SwiftUI

/// Loads the GitHub mark from `Resources/GithubMark.svg` (the user's own
/// downloaded copy of GitHub's official Invertocat asset) via macOS's
/// native `NSImage` SVG parser.
///
/// Why a bundled file rather than inlined SVG path data:
///   * The user supplied the asset themselves from GitHub's brand kit, so
///     the canonical copy stays in its own file — no source-tree mutation
///     of GitHub's mark, no risk of drifting from the official version.
///   * SwiftPM creates a `Clanker_Clanker.bundle` resource bundle. We look
///     it up manually instead of using `Bundle.module` because the generated
///     accessor traps if an installed app is missing that bundle.
///
/// The image is created once and cached. We mark it as a template image so
/// SwiftUI's `.foregroundStyle` tints it the same way it tints SF Symbols.
enum GithubMarkImage {
    /// Cached single instance. NSImage's SVG parser is cheap but there's no
    /// reason to redo it per row.
    static let shared: NSImage? = makeImage()

    private static func makeImage() -> NSImage? {
        guard let url = githubMarkURL(),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Template = monochrome silhouette honored by SwiftUI tint.
        image.isTemplate = true
        return image
    }

    static func githubMarkURL(
        in mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        if let url = mainBundle.url(forResource: "GithubMark", withExtension: "svg") {
            return url
        }

        let bundleName = "Clanker_Clanker.bundle"
        let candidateDirectories = [
            mainBundle.resourceURL?.appendingPathComponent(bundleName),
            mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
            mainBundle.bundleURL.appendingPathComponent(bundleName),
            mainBundle.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)")
        ].compactMap(\.self)

        return githubMarkURL(inCandidateDirectories: candidateDirectories, fileManager: fileManager)
    }

    static func githubMarkURL(
        inCandidateDirectories directories: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        directories
            .map { $0.appendingPathComponent("GithubMark.svg") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// SwiftUI wrapper around the GitHub mark with a system-symbol fallback if
/// the SVG fails to load (resource missing from the .app, parser failure,
/// etc.). The fallback keeps the action button functional even if the
/// resource pipeline breaks.
struct GithubMarkView: View {
    var body: some View {
        if let image = GithubMarkImage.shared {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
