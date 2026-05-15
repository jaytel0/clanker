import SwiftUI

/// One row inside the notch's "Recent" section.
///
/// Primary click opens the project in the preferred terminal. Hover reveals a
/// small trailing cluster of secondary actions (Finder, GitHub). Keeping the
/// row's resting state visually quiet preserves the clean look of the notch
/// when it first expands.
struct RecentProjectRow: View {
    let project: RecentProject
    let onPrimary: () -> Void
    let onFinder: () -> Void
    let onGithub: () -> Void

    @ObservedObject private var settings = RecentsSettings.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrimary) {
                primaryContent
            }
            .buttonStyle(.plain)
            .help("Open \(project.name) in \(TerminalLauncher.preferredDisplayName)")

            actionCluster
                .padding(.trailing, 8)
        }
        .notchRowChrome(
            hovering: hovering,
            accentColor: project.hasActiveSession ? NotchPalette.active : nil,
            restingOpacity: 0.04
        )
        .onHover { hovering = $0 }
    }

    private var primaryContent: some View {
        HStack(spacing: 9) {
            ProjectGlyph(hasActiveSession: project.hasActiveSession)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if project.hasActiveSession {
                        PulsingDot(color: NotchPalette.active, diameter: 5)
                    }
                }

                Text(abbreviatePath(project.path))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var actionCluster: some View {
        HStack(spacing: 4) {
            RecentActionIconButton(
                tooltip: "Reveal in Finder",
                action: onFinder
            ) {
                Image(systemName: "folder")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            RecentActionIconButton(
                tooltip: project.githubURL == nil ? "No GitHub remote" : "Open on GitHub",
                disabled: project.githubURL == nil,
                action: onGithub
            ) {
                // Official GitHub Invertocat mark, sized slightly larger
                // than the SF Symbol next to it because the Octicon has a
                // tighter optical bounding box than `folder`.
                GithubMarkView()
                    .frame(width: 18, height: 18)
            }
        }
        .opacity(hovering ? 1.0 : 0.55)
        .animation(NotchMotion.hover, value: hovering)
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Subviews

private struct ProjectGlyph: View {
    let hasActiveSession: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(width: 22, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var gradient: [Color] {
        if hasActiveSession {
            return [
                Color(red: 0.32, green: 0.68, blue: 0.46),
                Color(red: 0.18, green: 0.42, blue: 0.28)
            ]
        }
        return [
            Color(red: 0.26, green: 0.28, blue: 0.32),
            Color(red: 0.15, green: 0.16, blue: 0.19)
        ]
    }
}

private struct CategoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
    }
}

/// Generic 22pt action button used in the Recents row's right-side
/// cluster. Takes any icon view so we can mix SF Symbols (Finder) with the
/// bundled GitHub mark, while keeping the chrome (frame, hover background,
/// hover stroke, disabled fade) in one place.
private struct RecentActionIconButton<Icon: View>: View {
    let tooltip: String
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(.white.opacity(disabled ? 0.25 : (hovering ? 0.95 : 0.7)))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(hovering && !disabled ? 0.10 : 0.0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(hovering && !disabled ? 0.14 : 0.0), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .help(tooltip)
        .animation(NotchMotion.hover, value: hovering)
    }
}

// `PulsingDot` is declared `private` in `NotchRootView.swift`. We don't want
// to redeclare or expose it across files just for this one usage, so we
// recreate the smallest possible inline version here. Same visual recipe;
// kept tiny and local.
private struct PulsingDot: View {
    let color: Color
    var diameter: CGFloat = 5
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.55))
                .frame(width: diameter * 2.2, height: diameter * 2.2)
                .blur(radius: 3)
                .scaleEffect(pulsing ? 1.0 : 0.6)
                .opacity(pulsing ? 0 : 0.9)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: color.opacity(0.8), radius: 3)
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
