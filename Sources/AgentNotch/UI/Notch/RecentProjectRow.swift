import SwiftUI

/// One row inside the notch's "Recent" section.
///
/// Whole-row click = primary action (open in Ghostty). Hover reveals a small
/// trailing cluster of secondary actions (Finder, GitHub). Keeping the row's
/// resting state visually quiet preserves the clean look of the notch when
/// it first expands.
struct RecentProjectRow: View {
    let project: RecentProject
    let onPrimary: () -> Void
    let onFinder: () -> Void
    let onGithub: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPrimary) {
            content
        }
        .buttonStyle(RecentRowButtonStyle(hovering: hovering, hasActiveSession: project.hasActiveSession))
        .onHover { hovering = $0 }
        .help("Open \(project.name) in Ghostty")
    }

    private var content: some View {
        HStack(spacing: 10) {
            ProjectGlyph(hasActiveSession: project.hasActiveSession)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    CategoryChip(text: project.category)

                    if project.hasActiveSession {
                        PulsingDot(color: NotchPalette.active, diameter: 5)
                    }
                }

                Text(abbreviatePath(project.path))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            actionCluster
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var actionCluster: some View {
        HStack(spacing: 4) {
            RecentActionIconButton(
                systemName: "folder",
                tooltip: "Reveal in Finder",
                action: onFinder
            )
            RecentActionIconButton(
                systemName: "chevron.left.forwardslash.chevron.right",
                tooltip: project.githubURL == nil ? "No GitHub remote" : "Open on GitHub",
                disabled: project.githubURL == nil,
                action: onGithub
            )
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 26, height: 26)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var gradient: [Color] {
        if hasActiveSession {
            return [
                Color(red: 0.32, green: 0.72, blue: 0.46),
                Color(red: 0.18, green: 0.44, blue: 0.28)
            ]
        }
        return [
            Color(red: 0.32, green: 0.34, blue: 0.38),
            Color(red: 0.18, green: 0.19, blue: 0.22)
        ]
    }
}

private struct CategoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.08))
            )
    }
}

private struct RecentActionIconButton: View {
    let systemName: String
    let tooltip: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
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

private struct RecentRowButtonStyle: ButtonStyle {
    let hovering: Bool
    let hasActiveSession: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(pressed: configuration.isPressed))
            .overlay(alignment: .leading) {
                if hasActiveSession {
                    Capsule(style: .continuous)
                        .fill(NotchPalette.active)
                        .frame(width: 2.5)
                        .padding(.vertical, 9)
                        .shadow(color: NotchPalette.active.opacity(0.6), radius: 4)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.012 : 1.0))
            .animation(NotchMotion.hover, value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let opacity: Double = {
            if pressed { return 0.13 }
            if hovering { return 0.07 }
            return 0.04
        }()
        ZStack {
            shape.fill(.white.opacity(opacity))
            shape.stroke(.white.opacity(0.05), lineWidth: 0.5)
        }
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
