import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            RecentsSettingsView()
                .tabItem { Label("Recents", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section("Clanker") {
                Text("Local-first dynamic-notch monitor for coding-agent sessions.")
                Text("Harness adapters discover Codex, Claude, Pi, and bare terminal sessions automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Recents

private struct RecentsSettingsView: View {
    @ObservedObject private var settings = RecentsSettings.shared
    @State private var hookInstalled: Bool = CdHookInstaller.isInstalled()
    @State private var hookFeedback: String?

    var body: some View {
        Form {
            Section("Project Roots") {
                ForEach(Array(settings.roots.enumerated()), id: \.offset) { index, root in
                    HStack {
                        Text(abbreviate(root))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            settings.roots.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        addRoot()
                    } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                }

                Text("Each direct child of a root that contains a `.git` entry is treated as a recent project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cd Hook") {
                Toggle("Track `cd` events for sharper recency", isOn: hookBinding)
                Text("Installs a marker-delimited block in `~/.zshrc` that appends each `cd` to a private log Clanker reads. Without it, recency is inferred from `.git/` mtimes only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hookFeedback {
                    Text(hookFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            // Re-sync from disk in case the user edited `.zshrc` manually.
            hookInstalled = CdHookInstaller.isInstalled()
            settings.cdHookEnabled = hookInstalled
        }
    }

    /// Two-way binding that performs the install/uninstall side effect when
    /// the user flips the toggle, then mirrors the result back into both the
    /// local UI state and the persisted setting.
    private var hookBinding: Binding<Bool> {
        Binding(
            get: { hookInstalled },
            set: { newValue in
                let succeeded: Bool = newValue
                    ? CdHookInstaller.install()
                    : CdHookInstaller.uninstall()
                if succeeded {
                    hookInstalled = newValue
                    settings.cdHookEnabled = newValue
                    hookFeedback = newValue
                        ? "Installed. Open a new shell to start logging."
                        : "Removed. Existing log entries are kept."
                } else {
                    hookFeedback = "Could not modify ~/.zshrc — check file permissions."
                }
            }
        )
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Add Root"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !settings.roots.contains(path) {
                settings.roots.append(path)
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
