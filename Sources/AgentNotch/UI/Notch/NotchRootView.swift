import AppKit
import SwiftUI

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .top) {
            // Stage. Transparent so menu bar shows through; only the notch
            // shape paints anything visible.
            Color.clear

            notch
                .frame(
                    width: viewModel.isExpanded
                        ? NotchWindowController.expandedWidth
                        : NotchWindowController.closedWidth,
                    height: viewModel.isExpanded
                        ? NotchWindowController.expandedHeight
                        : NotchWindowController.closedHeight
                )
                .padding(.top, 0)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(
            width: NotchWindowController.canvasWidth,
            height: NotchWindowController.canvasHeight,
            alignment: .top
        )
        .environment(\.notchNamespace, glass)
    }

    private var notch: some View {
        let topRadius: CGFloat = viewModel.isExpanded ? 14 : 8
        let bottomRadius: CGFloat = viewModel.isExpanded ? 26 : 12

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
        .shadow(color: .black.opacity(viewModel.isExpanded ? 0.32 : 0.18),
                radius: viewModel.isExpanded ? 28 : 12,
                x: 0,
                y: viewModel.isExpanded ? 14 : 6)
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .onHover { hovering in
            viewModel.setHover(hovering)
        }
        .animation(NotchMotion.morph, value: viewModel.isExpanded)
    }
}

// MARK: - Notch shell

/// The black notch silhouette plus its inner highlight and outer hairline.
/// All visual depth lives here — content sits on top.
private struct NotchShell: View {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    var body: some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        ZStack {
            // Pure black body.
            shape.fill(.black)

            // Inner top highlight — gives the notch a faint "carved glass"
            // sheen as light grazes from above.
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.07),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            // Hairline rim — same trick Apple uses on Liquid Glass surfaces.
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
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
                Text("Agent Notch")
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
        VStack(alignment: .leading, spacing: 10) {
            ExpandedHeader(viewModel: viewModel, namespace: namespace)
                .padding(.horizontal, Self.edgeInset)

            Divider()
                .background(.white.opacity(0.08))
                .padding(.horizontal, Self.edgeInset)

            sessionList
        }
    }

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.sessions.isEmpty {
                    EmptyState()
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
            // Bottom inset so the last row clears the notch shape's curved
            // shoulders instead of slamming into them.
            .padding(.bottom, 18)
            .animation(NotchMotion.row, value: viewModel.sessions.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
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
                Text("Agent Notch")
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

private struct SessionGroupView: View {
    let group: SessionGroup
    let edgeInset: CGFloat
    let onActivate: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
                    .textCase(.uppercase)
                    .tracking(0.6)

                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
            }
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
                StatusPill(status: session.status)
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

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(status.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(backgroundOpacity))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(borderOpacity), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .active, .thinking, .runningTool:
            PulsingDot(color: tint, diameter: 5)
        case .waitingForApproval, .waitingForInput:
            PulsingDot(color: tint, diameter: 5, intensity: 1.2)
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint))
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint))
        case .idle:
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
        }
    }

    private var tint: Color {
        switch status {
        case .waitingForApproval, .waitingForInput: NotchPalette.attention
        case .active, .thinking, .runningTool: NotchPalette.active
        case .completed: NotchPalette.completed
        case .idle: NotchPalette.idle
        case .error: NotchPalette.error
        }
    }

    private var textColor: Color {
        switch status {
        case .idle: .white.opacity(0.55)
        default: .white.opacity(0.92)
        }
    }

    private var backgroundOpacity: Double {
        status == .idle ? 0.10 : 0.18
    }

    private var borderOpacity: Double {
        status == .idle ? 0.10 : 0.32
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
                        Text("π")
                            .font(.system(size: size * 0.66, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
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

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
            Text("All quiet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("No agent sessions are running.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

// MARK: - Palette

enum NotchPalette {
    static let attention = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let active = Color(red: 0.36, green: 0.85, blue: 0.45)
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
