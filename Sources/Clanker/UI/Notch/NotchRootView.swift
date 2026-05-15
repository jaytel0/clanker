import AppKit
import SwiftUI

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Namespace private var glass

    var body: some View {
        let notchWidth = viewModel.isExpanded
            ? NotchWindowController.expandedWidth
            : NotchWindowController.closedWidth
        let notchHeight = viewModel.isExpanded
            ? NotchWindowController.expandedHeight
            : NotchWindowController.closedHeight

        // The outer container is *always* the expanded panel size. The
        // AppKit panel never resizes; only the inner notch silhouette grows
        // and shrinks via the spring. Click-through is provided at the
        // window layer by `NotchPanel.ignoresMouseEvents`, not by sizing the
        // panel tight to the visible shape.
        ZStack(alignment: .top) {
            Color.clear

            notch
                .frame(width: notchWidth, height: notchHeight)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(
            width: NotchWindowController.expandedWidth,
            height: NotchWindowController.expandedHeight,
            alignment: .top
        )
        .environment(\.notchNamespace, glass)
    }

    private var notch: some View {
        let topRadius: CGFloat = viewModel.isExpanded
            ? NotchWindowController.expandedTopRadius
            : NotchWindowController.closedTopRadius
        let bottomRadius: CGFloat = viewModel.isExpanded
            ? NotchWindowController.expandedBottomRadius
            : NotchWindowController.closedBottomRadius

        return ZStack {
            NotchShell(topRadius: topRadius, bottomRadius: bottomRadius)

            Group {
                if viewModel.isExpanded {
                    ExpandedContent(viewModel: viewModel)
                        .padding(.top, 6)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: -4))
                                    .animation(NotchMotion.content.delay(0.06)),
                                removal: .opacity.animation(.easeOut(duration: 0.12))
                            )
                        )
                } else {
                    ClosedContent(viewModel: viewModel)
                        .padding(.horizontal, 18)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: 2))
                                    .animation(NotchMotion.content.delay(0.04)),
                                removal: .opacity.animation(.easeOut(duration: 0.10))
                            )
                        )
                }
            }
        }
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .compositingGroup()
        // Hover and click-to-toggle are driven globally by
        // `GlobalNotchEventMonitor` so they work even when the panel has
        // `ignoresMouseEvents = true` (closed state). SwiftUI's `.onHover`
        // and `.onTapGesture` would otherwise see nothing in that mode.
        .animation(NotchMotion.morph, value: viewModel.isExpanded)
    }
}

// MARK: - Notch shell

/// Pure black notch silhouette — no rim, no inner highlight, no gradient.
/// On a notched MacBook this blends seamlessly with the hardware notch so
/// the agent UI reads as a single extension of the physical cutout.
private struct NotchShell: View {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    var body: some View {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .fill(Color.black)
    }
}

// MARK: - Closed content

private struct ClosedContent: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.notchNamespace) private var namespace

    var body: some View {
        HStack(spacing: 8) {
            HarnessIconStack(
                harnesses: viewModel.representativeHarnesses,
                size: 18,
                namespace: namespace
            )

            Spacer(minLength: 4)

            ClosedStatusBadge(
                attentionCount: viewModel.attentionCount,
                activeCount: viewModel.activeCount
            )
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ClosedStatusBadge: View {
    let attentionCount: Int
    let activeCount: Int

    var body: some View {
        Group {
            if attentionCount > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: NotchPalette.attention)
                    Text("\(attentionCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NotchPalette.attention)
                }
                .transition(.scale.combined(with: .opacity))
            } else if activeCount > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: NotchPalette.active)
                    Text("\(activeCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.86))
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("Clanker")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .transition(.opacity)
            }
        }
        .animation(NotchMotion.content, value: attentionCount)
        .animation(NotchMotion.content, value: activeCount)
    }
}

// MARK: - Expanded content

private struct ExpandedContent: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.notchNamespace) private var namespace

    /// Horizontal inset applied to header / dividers / rows so they keep clear
    /// of the notch shape's curved walls. The ScrollView itself has no padding
    /// so content can scroll to the very bottom of the shape.
    private static let edgeInset: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExpandedHeader(viewModel: viewModel, namespace: namespace)
                .padding(.horizontal, Self.edgeInset)

            PaneTabBar(
                selected: viewModel.selectedPane,
                sessionsCount: viewModel.sessions.count,
                recentsCount: viewModel.recents.count,
                attentionCount: viewModel.attentionCount,
                onSelect: { viewModel.selectPane($0) }
            )
            .padding(.horizontal, Self.edgeInset)

            paneContent
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        // Both panes use the same tiny horizontal offset (4pt) plus an
        // opacity fade. SwiftUI applies the active animation
        // (`NotchMotion.tab` — system `.snappy`) to both insertion and
        // removal symmetrically, so the swap reads as a single quick slide
        // rather than a fade-and-then-slide. 4pt is barely visible but
        // gives the eye a direction cue.
        switch viewModel.selectedPane {
        case .sessions:
            sessionsPane
                .transition(
                    .opacity
                        .combined(with: .move(edge: .leading))
                        .animation(NotchMotion.tab)
                )
        case .recents:
            recentsPane
                .transition(
                    .opacity
                        .combined(with: .move(edge: .trailing))
                        .animation(NotchMotion.tab)
                )
        }
    }

    private var sessionsPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.sessions.isEmpty {
                    EmptyState(
                        icon: "moon.zzz.fill",
                        title: "All quiet",
                        subtitle: "No agent sessions are running."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(viewModel.groupedSessions) { group in
                        SessionGroupView(
                            group: group,
                            edgeInset: Self.edgeInset,
                            onActivate: { viewModel.activate($0) }
                        )
                    }
                }
            }
            .padding(.bottom, 18)
            .animation(NotchMotion.row, value: viewModel.sessions.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var recentsPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.recents.isEmpty {
                    EmptyState(
                        icon: "folder.badge.questionmark",
                        title: "No recent projects",
                        subtitle: "Add roots in Settings → Recents."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(viewModel.groupedRecents) { group in
                        RecentProjectGroupView(
                            group: group,
                            edgeInset: Self.edgeInset,
                            onPrimary: { viewModel.activate($0, action: .ghostty) },
                            onFinder: { viewModel.activate($0, action: .finder) },
                            onGithub: { viewModel.activate($0, action: .github) }
                        )
                    }
                }
            }
            .padding(.bottom, 18)
            .animation(NotchMotion.row, value: viewModel.recents.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Pane tabs

private struct PaneTabBar: View {
    let selected: NotchPane
    let sessionsCount: Int
    let recentsCount: Int
    let attentionCount: Int
    let onSelect: (NotchPane) -> Void

    var body: some View {
        HStack(spacing: 4) {
            tab(
                .sessions,
                count: sessionsCount,
                accentCount: attentionCount,
                accentColor: NotchPalette.attention
            )
            tab(
                .recents,
                count: recentsCount
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tab(
        _ pane: NotchPane,
        count: Int,
        accentCount: Int = 0,
        accentColor: Color = NotchPalette.active
    ) -> some View {
        let isSelected = pane == selected
        Button {
            onSelect(pane)
        } label: {
            HStack(spacing: 6) {
                Text(pane.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.5))

                if accentCount > 0 {
                    TabBadge(value: accentCount, tint: accentColor, prominent: true)
                } else if count > 0 {
                    TabBadge(
                        value: count,
                        tint: .white,
                        prominent: false,
                        emphasized: isSelected
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.10 : 0.0))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(isSelected ? 0.10 : 0.0), lineWidth: 0.5)
                    )
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(NotchMotion.hover, value: isSelected)
    }
}

private struct TabBadge: View {
    let value: Int
    let tint: Color
    var prominent: Bool = false
    var emphasized: Bool = false

    var body: some View {
        Text("\(value)")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(prominent ? .black.opacity(0.78) : .white.opacity(emphasized ? 0.92 : 0.55))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent
                          ? tint
                          : tint.opacity(emphasized ? 0.18 : 0.10))
            }
    }
}

private struct ExpandedHeader: View {
    @ObservedObject var viewModel: NotchViewModel
    let namespace: Namespace.ID?

    var body: some View {
        HStack(spacing: 10) {
            HarnessIconStack(
                harnesses: viewModel.representativeHarnesses,
                size: 22,
                namespace: namespace
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("Clanker")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.white)

                Text(headlineDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if viewModel.attentionCount > 0 {
                    HeaderPill(
                        text: "\(viewModel.attentionCount) attention",
                        tint: NotchPalette.attention,
                        leadingDot: true
                    )
                }
                HeaderPill(
                    text: "\(viewModel.activeCount) active",
                    tint: NotchPalette.active,
                    leadingDot: viewModel.activeCount > 0
                )
            }
        }
    }

    private var headlineDetail: String {
        let total = viewModel.sessions.count
        if total == 0 { return "No sessions" }
        if total == 1 { return "1 session" }
        return "\(total) sessions"
    }
}

private struct HeaderPill: View {
    let text: String
    let tint: Color
    let leadingDot: Bool

    var body: some View {
        HStack(spacing: 5) {
            if leadingDot {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .shadow(color: tint.opacity(0.7), radius: 4)
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.32), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Group + rows

private struct RecentProjectGroupView: View {
    let group: RecentProjectGroup
    let edgeInset: CGFloat
    let onPrimary: (RecentProject) -> Void
    let onFinder: (RecentProject) -> Void
    let onGithub: (RecentProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RecentProjectGroupHeader(group: group)
                .padding(.horizontal, edgeInset)

            VStack(spacing: 4) {
                ForEach(group.projects) { project in
                    RecentProjectRow(
                        project: project,
                        onPrimary: { onPrimary(project) },
                        onFinder: { onFinder(project) },
                        onGithub: { onGithub(project) }
                    )
                    .padding(.horizontal, edgeInset)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
        }
        .padding(.top, group.title == "Today" ? 0 : 8)
    }
}

private struct RecentProjectGroupHeader: View {
    let group: RecentProjectGroup

    var body: some View {
        HStack(spacing: 8) {
            Text(group.title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            if group.projects.count > 1 {
                Text("\(group.projects.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.07))
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 1)
    }
}

private struct SessionGroupView: View {
    let group: SessionGroup
    let edgeInset: CGFloat
    let onActivate: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SessionGroupHeader(group: group)
                .padding(.horizontal, edgeInset)

            VStack(spacing: 4) {
                ForEach(group.sessions) { session in
                    SessionRow(session: session, onActivate: { onActivate(session) })
                        .padding(.horizontal, edgeInset)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
        }
    }
}

/// Project header for a `SessionGroup`.
///
/// Treats the project as what it actually is — a filesystem path — rather
/// than dressing it up as a marketing-ish all-caps label. Renders as a
/// monospace breadcrumb ("personal/farm", with the parent dim and the
/// project bright) so the same visual language as Finder / Terminal /
/// Xcode comes through. A small count chip appears only when the project
/// has 2+ sessions, since the rows beneath already convey count visually
/// at 1.
private struct SessionGroupHeader: View {
    let group: SessionGroup

    @State private var hovering = false

    var body: some View {
        Button(action: openInFinder) {
            HStack(spacing: 8) {
                (
                    Text(parent.isEmpty ? "" : parent + "/")
                        .foregroundStyle(.white.opacity(hovering ? 0.45 : 0.32))
                    + Text(group.title)
                        .foregroundStyle(.white.opacity(hovering ? 0.98 : 0.85))
                        .fontWeight(.semibold)
                )
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

                if group.sessions.count > 1 {
                    Text("\(group.sessions.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                }

                // Reveal-in-Finder affordance: appears on hover so the
                // header reads cleanly at rest, then declares itself as
                // clickable the moment the cursor lands.
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.55 : 0))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hovering = isHovering
            // `.pointerStyle(.link)` only exists on macOS 15+; fall back to
            // the AppKit cursor stack so the deployment target stays at 14.
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Reveal \(displayPath) in Finder")
        .animation(NotchMotion.hover, value: hovering)
    }

    /// Open the project root in Finder. We use the *first* session's cwd
    /// rather than walking up to the repo root — if the user `cd`’d into a
    /// subdir, that subdir is what they're working in, and revealing the
    /// repo root would feel like a level-up they didn't ask for.
    private func openInFinder() {
        guard let path = expandedCWD else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Parent directory of the project's first session cwd, e.g. for
    /// `~/Developer/personal/clanker` returns `personal`. Empty string when we
    /// can't determine one (no sessions, weird path) — in that case the
    /// header just shows the project name with no breadcrumb prefix.
    private var parent: String {
        guard let path = expandedCWD else { return "" }
        let url = URL(fileURLWithPath: path)
        let parentName = url.deletingLastPathComponent().lastPathComponent
        // Skip degenerate parents like "/" or "\" so we don't render "//farm".
        guard !parentName.isEmpty, parentName != "/" else { return "" }
        return parentName
    }

    private var expandedCWD: String? {
        guard let cwd = group.sessions.first?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).expandingTildeInPath
    }

    private var displayPath: String {
        guard let path = expandedCWD else { return group.title }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let onActivate: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            rowContent
        }
        .buttonStyle(SessionRowButtonStyle(needsAttention: session.needsAttention, hovering: hovering))
        .onHover { hovering = $0 }
        .help(focusHelp)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            HarnessIcon(harness: session.harness, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let terminal = session.terminalName {
                        Text(terminal)
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

                Text(session.cwd)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(status: session.status, lastActivity: session.lastActivity)
                Text(relativeTime(session.lastActivity))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var focusHelp: String {
        if let terminal = session.terminalName {
            return "Focus \(terminal)"
        }
        return "Focus terminal"
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - Row button style

/// Owns press/hover visuals so the underlying `Button` can drive activation
/// reliably (no fighting with the parent `ScrollView`'s drag gesture).
private struct SessionRowButtonStyle: ButtonStyle {
    let needsAttention: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(pressed: configuration.isPressed))
            .overlay(alignment: .leading) {
                if needsAttention {
                    Capsule(style: .continuous)
                        .fill(NotchPalette.attention)
                        .frame(width: 2.5)
                        .padding(.vertical, 9)
                        .shadow(color: NotchPalette.attention.opacity(0.7), radius: 4)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.012 : 1.0))
            .animation(NotchMotion.hover, value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let baseOpacity: Double = {
            if pressed { return 0.13 }
            if needsAttention { return 0.085 }
            if hovering { return 0.07 }
            return 0.045
        }()

        ZStack {
            shape.fill(.white.opacity(baseOpacity))

            if needsAttention {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                NotchPalette.attention.opacity(0.10),
                                NotchPalette.attention.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            shape.stroke(.white.opacity(0.05), lineWidth: 0.5)
        }
    }
}

// MARK: - Status

private struct StatusPill: View {
    let status: SessionStatusKind
    /// Last time the underlying session produced output. Used to derive
    /// "Working\u{2026}" from `.active` / `.idle` rows when transcript bytes
    /// have been flowing recently. Pass `nil` to disable promotion.
    var lastActivity: Date? = nil

    /// Window during which a `.active` / `.idle` row should be shown as
    /// "Working\u{2026}" after the most recent transcript write. Tuned so
    /// short bursts of activity register but the pill returns to Idle
    /// promptly once the agent stops talking.
    private static let workingWindow: TimeInterval = 4

    var body: some View {
        // TimelineView gives the pill its own 1Hz clock so promotion to
        // Working and the auto-decay back to Idle happen continuously,
        // not just when the discovery loop fires (every few seconds).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            renderedPill(now: context.date)
        }
    }

    private func renderedPill(now: Date) -> some View {
        let effective = effectiveStatus(now: now)
        return HStack(spacing: 5) {
            indicator(for: effective)
            Text(effective.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor(for: effective))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            let t = tint(for: effective)
            Capsule(style: .continuous)
                .fill(t.opacity(backgroundOpacity(for: effective)))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(t.opacity(borderOpacity(for: effective)), lineWidth: 0.5)
                )
        }
        .animation(.easeInOut(duration: 0.18), value: effective)
    }

    /// What the pill actually displays. Source-of-truth statuses set by
    /// transcript parsers (.thinking, .runningTool) always count as Working.
    /// Ambient ".active" / ".idle" rows are promoted to Working only when
    /// there's been transcript activity inside `workingWindow`.
    private func effectiveStatus(now: Date) -> SessionStatusKind {
        switch status {
        case .working, .thinking, .runningTool:
            return .working
        case .active, .idle:
            if let lastActivity,
               now.timeIntervalSince(lastActivity) < Self.workingWindow {
                return .working
            }
            return .idle
        default:
            return status
        }
    }

    @ViewBuilder
    private func indicator(for status: SessionStatusKind) -> some View {
        switch status {
        case .working, .thinking, .runningTool:
            PulsingDot(color: tint(for: status), diameter: 5)
        case .waitingForApproval, .waitingForInput:
            PulsingDot(color: tint(for: status), diameter: 5, intensity: 1.2)
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint(for: status)))
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint(for: status)))
        case .active, .idle:
            Circle()
                .fill(tint(for: status))
                .frame(width: 5, height: 5)
        }
    }

    private func tint(for status: SessionStatusKind) -> Color {
        switch status {
        case .waitingForApproval, .waitingForInput: NotchPalette.attention
        case .working, .thinking, .runningTool: NotchPalette.working
        case .completed: NotchPalette.completed
        case .active, .idle: NotchPalette.idle
        case .error: NotchPalette.error
        }
    }

    private func textColor(for status: SessionStatusKind) -> Color {
        switch status {
        case .active, .idle: .white.opacity(0.55)
        default: .white.opacity(0.92)
        }
    }

    private func backgroundOpacity(for status: SessionStatusKind) -> Double {
        switch status {
        case .active, .idle: 0.10
        default: 0.18
        }
    }

    private func borderOpacity(for status: SessionStatusKind) -> Double {
        switch status {
        case .active, .idle: 0.10
        default: 0.32
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    var diameter: CGFloat = 6
    var intensity: Double = 1.0

    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.55 * intensity))
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

// MARK: - Harness icons

private struct HarnessIconStack: View {
    let harnesses: [HarnessID]
    let size: CGFloat
    let namespace: Namespace.ID?

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(harnesses.enumerated()), id: \.element) { index, harness in
                HarnessIcon(harness: harness, size: size)
                    .overlay(
                        // Subtle outline on overlap so icons read as a stack.
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .stroke(.black, lineWidth: index == 0 ? 0 : 1.4)
                    )
                    .zIndex(Double(harnesses.count - index))
                    .matchedGeometryNamespaceIfAvailable(harness, namespace: namespace, isLead: index == 0)
            }

            if harnesses.isEmpty {
                HarnessIcon(harness: .terminal, size: size)
            }
        }
    }
}

private struct HarnessIcon: View {
    let harness: HarnessID
    let size: CGFloat

    var body: some View {
        Group {
            if let image = appIcon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    if harness == .pi {
                        // Official Pi wordmark glyph (vector, exact path
                        // ported from Pi's published SVG). Renders sharp at
                        // every harness icon size and keeps the brand
                        // identity clean instead of relying on the system
                        // π codepoint, which renders inconsistently across
                        // SF Pro / SF Rounded weights.
                        PiLogoShape()
                            .fill(Color.white.opacity(0.95), style: FillStyle(eoFill: true))
                            .frame(width: size * 0.66, height: size * 0.66)
                    } else {
                        Image(systemName: harness.symbolName)
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .help(harness.displayName)
    }

    private var appIcon: NSImage? {
        let bundleID: String?
        switch harness {
        case .codex: bundleID = "com.openai.codex"
        case .claude: bundleID = "com.anthropic.claudefordesktop"
        case .pi, .terminal: bundleID = nil
        }
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var gradient: [Color] {
        switch harness {
        case .codex:
            [Color(red: 0.18, green: 0.18, blue: 0.20), Color(red: 0.05, green: 0.05, blue: 0.07)]
        case .claude:
            [Color(red: 0.96, green: 0.55, blue: 0.34), Color(red: 0.78, green: 0.34, blue: 0.18)]
        case .pi:
            [Color(red: 0.34, green: 0.36, blue: 0.95), Color(red: 0.20, green: 0.18, blue: 0.62)]
        case .terminal:
            [Color(red: 0.30, green: 0.32, blue: 0.36), Color(red: 0.15, green: 0.16, blue: 0.18)]
        }
    }
}

// MARK: - Empty state

/// Generic empty-state copy for any pane. Both panes share the same visual
/// recipe (icon + title + subtitle) so the surface stays consistent when the
/// user flips between tabs.
private struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

// MARK: - Palette

enum NotchPalette {
    static let attention = Color(red: 1.00, green: 0.78, blue: 0.30)
    /// Reserved for the legacy `.active` color slot — unused now that
    /// `.active` displays as Idle. Kept for any callers that still reference
    /// it (currently the closed-bar accent ring).
    static let active = Color(red: 0.36, green: 0.85, blue: 0.45)
    /// Vivid system green for actively-producing agents ("Working\u{2026}").
    /// Mirrors the SF system green so it reads as the same "live activity"
    /// color used by macOS itself.
    static let working = Color(red: 0.30, green: 0.85, blue: 0.39)
    static let completed = Color(red: 0.45, green: 0.78, blue: 0.95)
    static let idle = Color.white.opacity(0.5)
    static let error = Color(red: 0.98, green: 0.42, blue: 0.42)
}

// MARK: - Namespace plumbing

private struct NotchNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var notchNamespace: Namespace.ID? {
        get { self[NotchNamespaceKey.self] }
        set { self[NotchNamespaceKey.self] = newValue }
    }
}

private extension View {
    @ViewBuilder
    func matchedGeometryNamespaceIfAvailable(
        _ harness: HarnessID,
        namespace: Namespace.ID?,
        isLead: Bool
    ) -> some View {
        if let namespace, isLead {
            self.matchedGeometryEffect(id: "harness-\(harness.rawValue)", in: namespace)
        } else {
            self
        }
    }
}
