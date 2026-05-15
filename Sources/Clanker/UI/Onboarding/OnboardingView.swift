import AppKit
import SwiftUI

// MARK: - Suggested root

struct SuggestedRoot: Identifiable {
    let id = UUID()
    let path: String
    var isSelected: Bool

    var displayPath: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var label: String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Scanner

enum OnboardingScanner {
    /// Returns the folders we think are developer roots, pre-sorted and
    /// pre-selected if they contain at least one git repo.
    static func suggestedRoots() -> [SuggestedRoot] {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // Candidate paths — ordered by how likely they are to be useful
        var candidates: [String] = []

        // 1. Subdirectories of ~/Developer (personal, shopify, work, oss, tries…)
        let developerDir = (home as NSString).appendingPathComponent("Developer")
        if let subs = try? fm.contentsOfDirectory(atPath: developerDir) {
            for sub in subs.sorted() where !sub.hasPrefix(".") {
                candidates.append((developerDir as NSString).appendingPathComponent(sub))
            }
        }

        // 2. ~/Developer itself (flat layout — all repos directly inside)
        candidates.append(developerDir)

        // 3. Other common roots
        for name in ["code", "repos", "projects", "src", "work"] {
            candidates.append((home as NSString).appendingPathComponent(name))
        }

        var seen = Set<String>()
        var results: [SuggestedRoot] = []

        for path in candidates {
            let normalized = (path as NSString).standardizingPath
            guard seen.insert(normalized).inserted else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else { continue }

            let hasGit = hasAnyGitRepo(at: normalized)
            results.append(SuggestedRoot(path: normalized, isSelected: hasGit))
        }

        // Show selected first, then the rest alphabetically
        return results.sorted {
            if $0.isSelected != $1.isSelected { return $0.isSelected }
            return $0.path < $1.path
        }
    }

    private static func hasAnyGitRepo(at root: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return false
        }
        return entries.contains { entry in
            let gitPath = (root as NSString)
                .appendingPathComponent(entry)
                .appending("/.git")
            return FileManager.default.fileExists(atPath: gitPath)
        }
    }
}

// MARK: - View

struct OnboardingView: View {
    var onComplete: ([String]) -> Void

    @ObservedObject private var settings = RecentsSettings.shared
    @State private var suggestions: [SuggestedRoot] = []
    @State private var isScanning = true

    var selectedPaths: [String] {
        suggestions.filter(\.isSelected).map(\.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            VStack(spacing: 12) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text("Welcome to Clanker")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Choose the folders where your projects live.\nClanker will surface recent ones in the notch.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.top, 36)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)

            Divider()
                .background(.white.opacity(0.08))

            // ── Folder list ─────────────────────────────────────────────
            ScrollView {
                LazyVStack(spacing: 2) {
                    if isScanning {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.4))
                            Text("Scanning…")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else if suggestions.isEmpty {
                        Text("No project folders found automatically.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach($suggestions) { $root in
                            RootRow(root: $root)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(height: 220)

            // ── Add folder ──────────────────────────────────────────────
            Button {
                addFolder()
            } label: {
                Label("Add folder…", systemImage: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)

            TerminalPreferenceRow(selectedBundleID: terminalBinding)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

            Divider()
                .background(.white.opacity(0.08))

            // ── Footer ───────────────────────────────────────────────────
            HStack {
                Button("Skip") {
                    onComplete([])
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                Button("Get Started") {
                    onComplete(selectedPaths)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedPaths.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.10))
        .task {
            let roots = await Task.detached(priority: .userInitiated) {
                OnboardingScanner.suggestedRoots()
            }.value
            suggestions = roots
            isScanning = false
        }
    }

    private var terminalBinding: Binding<String> {
        Binding(
            get: { settings.preferredTerminalApp.bundleID },
            set: { settings.preferredTerminalBundleID = $0 }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = (url.path as NSString).standardizingPath
            if !suggestions.contains(where: { $0.path == path }) {
                suggestions.append(SuggestedRoot(path: path, isSelected: true))
            } else if let idx = suggestions.firstIndex(where: { $0.path == path }) {
                suggestions[idx].isSelected = true
            }
        }
    }
}

// MARK: - Terminal preference

private struct TerminalPreferenceRow: View {
    @Binding var selectedBundleID: String
    @State private var hovering = false

    private var selectedTerminal: TerminalApp {
        TerminalApp.resolving(bundleID: selectedBundleID)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Default terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Recent projects open in \(selectedTerminal.displayName).")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer()

            Menu {
                ForEach(TerminalApp.installedForSelection) { terminal in
                    Button {
                        selectedBundleID = terminal.bundleID
                    } label: {
                        HStack {
                            Text(terminal.displayName)
                            if terminal == selectedTerminal {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedTerminal.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.12 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: hovering)
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: selectedBundleID)
    }
}

// MARK: - Root row

private struct RootRow: View {
    @Binding var root: SuggestedRoot
    @State private var hovering = false

    var body: some View {
        Button {
            root.isSelected.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: root.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(root.isSelected ? Color.accentColor : .white.opacity(0.25))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(root.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(root.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: hovering)
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: root.isSelected)
    }
}

// MARK: - Button styles

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.80 : 1.0))
            )
            .animation(.spring(response: 0.18, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.35 : 0.45))
            .animation(.spring(response: 0.18, dampingFraction: 0.82), value: configuration.isPressed)
    }
}
