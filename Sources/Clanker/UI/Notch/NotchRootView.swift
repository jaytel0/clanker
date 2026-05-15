import AppKit
import SwiftUI

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Namespace private var glass

    var body: some View {
        let notchWidth = viewModel.isExpanded
            ? NotchWindowController.expandedWidth
            : viewModel.currentClosedWidth
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
        .animation(NotchMotion.morph, value: topRadius)
        .animation(NotchMotion.morph, value: bottomRadius)
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
                Text("0")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.36))
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

            paneContent
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        // Directional transition: the entering pane slides in from the
        // direction you're navigating toward, and the exiting pane slides
        // out the opposite way — like a camera panning along a horizontal
        // strip of [Sessions | Recents | Spend].
        let insertionEdge: Edge = viewModel.tabDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = viewModel.tabDirection == .forward ? .leading : .trailing

        Group {
            switch viewModel.selectedPane {
            case .sessions: sessionsPane
            case .recents:  recentsPane
            case .spend:    spendPane
            }
        }
        .id(viewModel.selectedPane)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: insertionEdge)),
                removal: .opacity.combined(with: .move(edge: removalEdge))
            )
            .animation(NotchMotion.tab)
        )
    }

    private var sessionsPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
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
                            onActivate: { viewModel.activate($0) },
                            onClose: { viewModel.closeSession($0, allowProcessTermination: $1) }
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
                            onPrimary: { viewModel.activate($0, action: .terminal) },
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

    private var spendPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                let summary = viewModel.spendSummary
                SpendTimeframePicker(
                    selected: viewModel.selectedSpendTimeframe,
                    onSelect: { viewModel.selectSpendTimeframe($0) }
                )
                .padding(.horizontal, Self.edgeInset)

                if summary.snapshots.isEmpty {
                    EmptyState(
                        icon: "chart.bar.xaxis",
                        title: "No spend yet",
                        subtitle: "No usage snapshots in \(summary.timeframe.title.lowercased())."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    SpendOverview(summary: summary)
                        .padding(.horizontal, Self.edgeInset)

                    SpendBreakdownSection(
                        title: "By harness",
                        items: summary.byHarness,
                        rowKind: .harness
                    )

                    SpendBreakdownSection(
                        title: "By project",
                        items: Array(summary.byProject.prefix(8)),
                        rowKind: .project
                    )
                }
            }
            .padding(.bottom, 18)
            .animation(NotchMotion.row, value: viewModel.usageSnapshots.map(\.id))
            .animation(NotchMotion.tab, value: viewModel.selectedSpendTimeframe)
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
    let spendCount: Int
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
                count: recentsCount,
                showsCount: false
            )
            tab(
                .spend,
                count: spendCount,
                showsCount: false
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tab(
        _ pane: NotchPane,
        count: Int,
        accentCount: Int = 0,
        accentColor: Color = NotchPalette.active,
        showsCount: Bool = true
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
                } else if showsCount, count > 0 {
                    TabBadge(
                        value: count,
                        tint: .white,
                        prominent: false,
                        emphasized: isSelected
                    )
                }
            }
            .frame(minWidth: 78, minHeight: 24)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.10 : 0.0))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(isSelected ? 0.10 : 0.0), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .frame(minWidth: 98, minHeight: 32)
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
        HStack(spacing: 6) {
            PaneTabBar(
                selected: viewModel.selectedPane,
                sessionsCount: viewModel.sessions.count,
                recentsCount: viewModel.recents.count,
                spendCount: viewModel.spendSummary.snapshots.count,
                attentionCount: viewModel.attentionCount,
                onSelect: { viewModel.selectPane($0) }
            )

            Spacer(minLength: 8)

            if viewModel.attentionCount > 0 {
                HeaderPill(
                    text: "\(viewModel.attentionCount) attention",
                    tint: NotchPalette.attention,
                    leadingDot: true
                )
            }
            if viewModel.updateManager.availableUpdate != nil || viewModel.updateManager.state.isBusy {
                UpdatePill(updateManager: viewModel.updateManager)
            }
            DisplayLockButton()
            SettingsCogButton(
                updateManager: viewModel.updateManager,
                onShowOnboarding: viewModel.onShowOnboarding ?? {}
            )
        }
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

// MARK: - Update + settings controls

private struct UpdatePill: View {
    @ObservedObject var updateManager: GitHubUpdateManager
    @State private var hovering = false

    var body: some View {
        Button {
            if updateManager.availableUpdate?.assetURL != nil {
                updateManager.installAvailableUpdate()
            } else {
                updateManager.openAvailableReleasePage()
            }
        } label: {
            HeaderPill(
                text: title,
                tint: NotchPalette.update,
                leadingDot: !updateManager.state.isBusy
            )
        }
        .buttonStyle(.plain)
        .disabled(updateManager.state.isBusy)
        .opacity(hovering ? 1.0 : 0.86)
        .onHover { hovering = $0 }
        .help(helpText)
        .animation(NotchMotion.hover, value: hovering)
    }

    private var title: String {
        switch updateManager.state {
        case .checking:
            return "Checking"
        case .downloading:
            return "Downloading"
        case .installing:
            return "Installing"
        default:
            if let update = updateManager.availableUpdate {
                return "Update \(update.version)"
            }
            return "Update"
        }
    }

    private var helpText: String {
        guard let update = updateManager.availableUpdate else { return updateManager.state.statusText }
        if update.assetURL == nil { return "View Clanker \(update.version) on GitHub" }
        return "Install Clanker \(update.version)"
    }
}

// MARK: - Display lock

private struct DisplayLockButton: View {
    @ObservedObject private var settings = NotchDisplaySettings.shared
    @State private var hovering = false
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(hovering || !settings.isFollowingActiveDisplay ? 0.16 : 0.08))
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(hovering || !settings.isFollowingActiveDisplay ? 0.18 : 0.10), lineWidth: 0.5)
                    )

                Image(systemName: settings.isFollowingActiveDisplay ? "display" : "display")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering || !settings.isFollowingActiveDisplay ? 0.95 : 0.78))
            }
            .frame(width: 25, height: 25)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering = $0 }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            DisplayLockPopover(
                settings: settings,
                onDismiss: { isPopoverPresented = false }
            )
        }
        .animation(NotchMotion.hover, value: hovering)
        .animation(NotchMotion.hover, value: settings.isFollowingActiveDisplay)
    }

    private var helpText: String {
        if settings.isFollowingActiveDisplay {
            return "Following active display"
        }
        if let name = settings.lockedDisplayName {
            return "Locked to \(name)"
        }
        return "Locked to display"
    }
}

private struct DisplayLockPopover: View {
    @ObservedObject var settings: NotchDisplaySettings
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notch Display")
                .font(.system(size: 12, weight: .semibold))
                .padding(.bottom, 2)

            Button {
                settings.followActiveDisplay()
                onDismiss()
            } label: {
                displayOptionLabel(
                    title: "Follow Active Display",
                    systemImage: "arrow.triangle.2.circlepath",
                    isSelected: settings.isFollowingActiveDisplay
                )
            }
            .buttonStyle(.plain)

            if settings.availableDisplays.count > 1 {
                Divider()

                ForEach(settings.availableDisplays) { display in
                    Button {
                        settings.lock(to: display.id)
                        onDismiss()
                    } label: {
                        displayOptionLabel(
                            title: display.name,
                            systemImage: display.iconName,
                            isSelected: settings.lockedDisplayID == display.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
    }

    private func displayOptionLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? NotchPalette.active : .secondary)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings cog

private struct SettingsCogButton: View {
    @ObservedObject var updateManager: GitHubUpdateManager
    let onShowOnboarding: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            updateMenuItems

            Divider()

            Button {
                onShowOnboarding()
            } label: {
                Label("Choose Sources…", systemImage: "folder.badge.gearshape")
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Clanker", systemImage: "power")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(hovering ? 0.16 : 0.08))
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(hovering ? 0.18 : 0.10), lineWidth: 0.5)
                        )

                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundColor(.white.opacity(hovering ? 0.95 : 0.78))
                }
                .frame(width: 25, height: 25)

                if updateManager.availableUpdate != nil {
                    Circle()
                        .fill(NotchPalette.update)
                        .frame(width: 6, height: 6)
                        .shadow(color: NotchPalette.update.opacity(0.7), radius: 3)
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Circle())
        }
        .colorScheme(.dark)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(NotchMotion.hover, value: hovering)
    }

    @ViewBuilder
    private var updateMenuItems: some View {
        if let update = updateManager.availableUpdate {
            Button {
                updateManager.installAvailableUpdate()
            } label: {
                Label("Install Clanker \(update.version)…", systemImage: "arrow.down.app")
            }
            .disabled(updateManager.state.isBusy || update.assetURL == nil)

            Button {
                updateManager.openAvailableReleasePage()
            } label: {
                Label("View Release Notes", systemImage: "doc.text")
            }

            Button {
                updateManager.skipAvailableUpdate()
            } label: {
                Label("Skip This Version", systemImage: "forward.end")
            }
            .disabled(updateManager.state.isBusy)
        } else {
            Button {
                updateManager.checkNow()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.clockwise")
            }
            .disabled(updateManager.state.isBusy)
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
        VStack(alignment: .leading, spacing: 4) {
            if group.title != "Today" {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, edgeInset)
                    .padding(.top, 6)
            }

            RecentProjectGroupHeader(group: group)
                .padding(.horizontal, edgeInset)

            VStack(spacing: 2) {
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
    }
}

private struct RecentProjectGroupHeader: View {
    let group: RecentProjectGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

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
    let onClose: (AgentSession, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SessionGroupHeader(group: group)
                .padding(.horizontal, edgeInset)

            VStack(spacing: 2) {
                ForEach(group.sessions) { session in
                    SessionRow(
                        session: session,
                        groupCwd: group.sessions.first?.cwd,
                        onActivate: { onActivate(session) },
                        onClose: { allowTermination in onClose(session, allowTermination) }
                    )
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
            HStack(spacing: 6) {
                (
                    Text(parent.isEmpty ? "" : parent + "/")
                        .foregroundStyle(.white.opacity(hovering ? 0.45 : 0.28))
                    + Text(group.title)
                        .foregroundStyle(.white.opacity(hovering ? 0.98 : 0.78))
                        .fontWeight(.semibold)
                )
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

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
    /// The cwd of the group — when the session's cwd matches, we hide it
    /// to avoid repeating what the group header already states.
    var groupCwd: String? = nil
    let onActivate: () -> Void
    var onClose: (Bool) -> Void = { _ in }

    @State private var hovering = false
    @State private var showingCloseConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                primaryContent
            }
            .buttonStyle(.plain)
            .help(focusHelp)

            if (hovering || showingCloseConfirmation), session.closeCapability.canClose {
                SessionCloseButton(
                    capability: session.closeCapability,
                    action: handleCloseTap
                )
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if session.needsAttention {
                Capsule(style: .continuous)
                    .fill(NotchPalette.attention)
                    .frame(width: 2.5)
                    .padding(.vertical, 9)
                    .shadow(color: NotchPalette.attention.opacity(0.7), radius: 4)
            }
        }
        .scaleEffect(hovering ? 1.012 : 1.0)
        .onHover { hovering = $0 }
        .alert("Terminate process group?", isPresented: $showingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Terminate", role: .destructive) {
                onClose(true)
            }
        } message: {
            Text("Clanker could not close this through a terminal tab. Terminating sends SIGTERM to the owned process group.")
        }
        .animation(NotchMotion.hover, value: hovering)
    }

    private var showCwd: Bool {
        guard let groupCwd else { return true }
        return session.cwd != groupCwd
    }

    private var primaryContent: some View {
        HStack(spacing: 9) {
            HarnessIcon(harness: session.harness, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if showCwd {
                    Text(session.cwd)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            CompactStatus(status: session.status, lastActivity: session.lastActivity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var focusHelp: String {
        if let terminal = session.terminalName {
            return "Focus \(terminal)"
        }
        return "Focus terminal"
    }

    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let baseOpacity: Double = {
            if session.needsAttention { return 0.085 }
            if hovering { return 0.07 }
            return 0.045
        }()

        return ZStack {
            shape.fill(.white.opacity(baseOpacity))

            if session.needsAttention {
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

    private func handleCloseTap() {
        if session.closeCapability.requiresConfirmation {
            showingCloseConfirmation = true
        } else {
            onClose(false)
        }
    }
}

private struct SessionCloseButton: View {
    let capability: SessionCloseCapability
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? .white : .white.opacity(0.5))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(hovering ? Color.red.opacity(0.85) : .white.opacity(0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(capability.helpTitle)
        .animation(NotchMotion.hover, value: hovering)
    }
}

// MARK: - Spend

private struct SpendOverview: View {
    let summary: SpendSummary

    var body: some View {
        HStack(spacing: 8) {
            SpendMetric(
                title: "Spend",
                value: SpendFormatting.cost(summary.totalCostUSD),
                detail: summary.costSource.title
            )
            SpendMetric(
                title: "Tokens",
                value: SpendFormatting.tokens(summary.totalTokens),
                detail: "Observed"
            )
            SpendMetric(
                title: "Events",
                value: "\(summary.snapshots.count)",
                detail: summary.timeframe.title
            )
        }
    }
}

private struct SpendTimeframePicker: View {
    let selected: SpendTimeframe
    let onSelect: (SpendTimeframe) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)

            ForEach(SpendTimeframe.allCases) { timeframe in
                let isSelected = timeframe == selected
                Button {
                    onSelect(timeframe)
                } label: {
                    Text(timeframe.shortLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? .white.opacity(0.94) : .white.opacity(0.44))
                        .frame(width: 28, height: 28)
                        .background {
                            Circle()
                                .fill(.white.opacity(isSelected ? 0.12 : 0.0))
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(isSelected ? 0.14 : 0.06), lineWidth: 0.5)
                                )
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .animation(NotchMotion.hover, value: isSelected)
            }
        }
    }
}

private struct SpendMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(detail)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

private enum SpendBreakdownRowKind {
    case harness
    case project
}

private struct SpendBreakdownSection: View {
    let title: String
    let items: [SpendBreakdownItem]
    let rowKind: SpendBreakdownRowKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)

            VStack(spacing: 2) {
                ForEach(items) { item in
                    SpendBreakdownRow(item: item, rowKind: rowKind)
                        .padding(.horizontal, 22)
                }
            }
        }
    }
}

private struct SpendBreakdownRow: View {
    let item: SpendBreakdownItem
    let rowKind: SpendBreakdownRowKind

    var body: some View {
        HStack(spacing: 9) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Text(SpendFormatting.cost(item.costUSD))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.costUSD == nil ? .white.opacity(0.48) : .white.opacity(0.92))

                    SpendSourceBadge(source: item.costSource)
                }

                Text("\(SpendFormatting.tokens(item.tokens.knownTotal)) tokens")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.05), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if rowKind == .harness, let harness = item.harness {
            HarnessIcon(harness: harness, size: 22)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchPalette.spend.opacity(0.9))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NotchPalette.spend.opacity(0.13))
                )
        }
    }
}

private struct SpendSourceBadge: View {
    let source: UsageCostSource

    var body: some View {
        Text(source.title)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(tint.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.13))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.24), lineWidth: 0.5)
                    )
            }
    }

    private var tint: Color {
        switch source {
        case .reported: NotchPalette.active
        case .estimated: NotchPalette.spend
        case .quotaOnly: NotchPalette.completed
        case .unknown: NotchPalette.idle
        }
    }
}

// MARK: - Status

/// Compact inline status: colored dot + relative time for normal states,
/// full attention pill only for states that need user action.
private struct CompactStatus: View {
    let status: SessionStatusKind
    var lastActivity: Date? = nil

    private static let workingWindow: TimeInterval = 4

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            rendered(now: context.date)
        }
    }

    private func rendered(now: Date) -> some View {
        let effective = effectiveStatus(now: now)
        return Group {
            if effective.needsAttention {
                // Full pill only for attention states
                attentionPill(for: effective)
            } else {
                // Minimal: dot + time
                HStack(spacing: 5) {
                    statusIndicator(for: effective)
                    Text(relativeTime(lastActivity ?? now, now: now))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: effective)
    }

    private func attentionPill(for status: SessionStatusKind) -> some View {
        HStack(spacing: 5) {
            PulsingDot(color: tint(for: status), diameter: 5, intensity: 1.2)
            Text(status.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            let t = tint(for: status)
            Capsule(style: .continuous)
                .fill(t.opacity(0.18))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(t.opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private func statusIndicator(for status: SessionStatusKind) -> some View {
        switch status {
        case .working, .thinking, .runningTool:
            PulsingDot(color: tint(for: status), diameter: 5)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint(for: status)))
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint(for: status)))
        default:
            Circle()
                .fill(tint(for: status))
                .frame(width: 5, height: 5)
        }
    }

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

    private func tint(for status: SessionStatusKind) -> Color {
        switch status {
        case .waitingForApproval, .waitingForInput: NotchPalette.attention
        case .working, .thinking, .runningTool: NotchPalette.working
        case .completed: NotchPalette.completed
        case .active, .idle: NotchPalette.idle
        case .error: NotchPalette.error
        }
    }

    private func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
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
    static let attention = Color(red: 0.94, green: 0.76, blue: 0.34)
    static let active = Color(red: 0.38, green: 0.78, blue: 0.48)
    /// Slightly desaturated green for working state — reads clearly on
    /// black without being garish.
    static let working = Color(red: 0.36, green: 0.80, blue: 0.44)
    static let completed = Color(red: 0.48, green: 0.74, blue: 0.90)
    static let update = Color(red: 0.48, green: 0.70, blue: 0.96)
    static let spend = Color(red: 0.76, green: 0.64, blue: 0.96)
    static let idle = Color.white.opacity(0.45)
    static let error = Color(red: 0.92, green: 0.44, blue: 0.42)
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
