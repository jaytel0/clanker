import AppKit
import Combine
import Foundation
import SwiftUI

/// Top-level pane shown inside the expanded notch. Each pane is a focused
/// list with its own scroll state — keeps the surface scannable when there
/// are many sessions, instead of burying recents at the bottom of one
/// combined scroll.
enum NotchPane: String, CaseIterable, Identifiable, Sendable {
    case sessions
    case recents
    case spend

    var id: String { rawValue }

    init?(shortcutKey: String?) {
        switch shortcutKey {
        case "1": self = .sessions
        case "2": self = .recents
        case "3": self = .spend
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .sessions: "Clankers"
        case .recents: "Projects"
        case .spend: "Spend"
        }
    }
}

enum TabDirection: Equatable {
    case forward  // moving right (higher index)
    case backward // moving left (lower index)
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isHovering = false
    @Published var selectedPane: NotchPane = .sessions
    @Published private(set) var tabDirection: TabDirection = .forward
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var recents: [RecentProject] = []
    @Published private(set) var usageSnapshots: [HarnessUsageSnapshot] = []
    @Published var selectedSpendTimeframe: SpendTimeframe = .today
    @Published private(set) var isDemoMode = UserDefaults.standard.bool(forKey: NotchDemoMode.defaultsKey)

    /// Set by the controller so the view knows which display type is active.
    @Published var screenHasNotch = false

    /// The current effective closed width based on screen type.
    var currentClosedWidth: CGFloat {
        screenHasNotch
            ? NotchWindowController.closedWidthNotched
            : NotchWindowController.closedWidthFlat
    }

    private let sessionStore: LocalSessionStore
    private let recentsStore: RecentProjectsStore?
    private let usageStore: HarnessUsageStore?
    let updateManager: GitHubUpdateManager
    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?

    /// Filled in by `AppDelegate` so the settings menu can trigger the
    /// onboarding flow without the view layer knowing about AppKit windows.
    var onShowOnboarding: (() -> Void)?

    init(
        sessionStore: LocalSessionStore,
        recentsStore: RecentProjectsStore? = nil,
        usageStore: HarnessUsageStore? = nil,
        updateManager: GitHubUpdateManager = .shared
    ) {
        self.sessionStore = sessionStore
        self.recentsStore = recentsStore
        self.usageStore = usageStore
        self.updateManager = updateManager

        sessionStore.$sessions
            .removeDuplicates()
            .sink { [weak self] sessions in
                // Only surface sessions backed by a currently running
                // process / app / live terminal AND not finished. Transcript
                // history and completed runs are useful internal context for
                // the merger but they must not appear in the UI — ground
                // truth is "is this thing actually running right now?"
                // (matches what `w` shows for live TTYs).
                self?.sessions = sessions
                    .filter { $0.isLive && $0.status != .completed }
                    .sortedForNotch()
            }
            .store(in: &cancellables)

        recentsStore?.$recents
            .removeDuplicates()
            .sink { [weak self] recents in
                self?.recents = recents
            }
            .store(in: &cancellables)

        usageStore?.$snapshots
            .removeDuplicates()
            .sink { [weak self] snapshots in
                self?.usageSnapshots = snapshots
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    /// Open/live rows shown in the Clankers tab.
    var openCount: Int {
        visibleSessions.count
    }

    /// Rows that are currently doing work. `.active` and `.idle` mean the
    /// session exists, not that output is flowing; attention states are counted
    /// separately so the closed badge has one unambiguous number.
    var workingCount: Int {
        visibleSessions.filter { $0.countsAsLiveActive && !$0.needsAttention }.count
    }

    var attentionCount: Int {
        visibleSessions.filter(\.needsAttention).count
    }

    var representativeSession: AgentSession? {
        visibleSessions.first(where: \.needsAttention) ?? visibleSessions.first
    }

    /// Up to three harness icons to fan out in the closed bar.
    var representativeHarnesses: [HarnessID] {
        var seen: [HarnessID] = []
        for session in visibleSessions {
            if !seen.contains(session.harness) {
                seen.append(session.harness)
            }
            if seen.count == 3 { break }
        }
        return seen
    }

    var groupedSessions: [SessionGroup] {
        Dictionary(grouping: visibleSessions, by: \.projectName)
            .map { SessionGroup(title: $0.key, sessions: $0.value.sortedForNotch()) }
            .sorted { lhs, rhs in
                let lhsAttention = lhs.sessions.contains(where: \.needsAttention)
                let rhsAttention = rhs.sessions.contains(where: \.needsAttention)
                if lhsAttention != rhsAttention { return lhsAttention }
                let lhsActivity = lhs.sessions.first?.lastActivity ?? .distantPast
                let rhsActivity = rhs.sessions.first?.lastActivity ?? .distantPast
                return lhsActivity > rhsActivity
            }
    }

    var groupedRecents: [RecentProjectGroup] {
        RecentProjectGroup.group(visibleRecents)
    }

    var spendSummary: SpendSummary {
        SpendSummary(snapshots: visibleUsageSnapshots, timeframe: selectedSpendTimeframe)
    }

    var visibleSessions: [AgentSession] {
        guard isDemoMode else { return sessions }
        return sessions.filter(NotchDemoMode.isPersonalSession)
    }

    var visibleRecents: [RecentProject] {
        guard isDemoMode else { return recents }
        return recents.filter(NotchDemoMode.isPersonalProject)
    }

    var visibleUsageSnapshots: [HarnessUsageSnapshot] {
        guard isDemoMode else { return usageSnapshots }
        return NotchDemoMode.demoUsageSnapshots()
    }

    // MARK: - Intent

    func toggleExpanded() {
        cancelHoverTasks()
        if !isExpanded {
            // Refresh recents right as the user opens the notch so the list
            // is current at the moment they look at it. Cheap — a few stat
            // calls per repo.
            recentsStore?.refreshOnDemand()
            usageStore?.refreshNow()
        }
        withAnimation(NotchMotion.morph) {
            isExpanded.toggle()
        }
    }

    /// Switch to a different pane inside the expanded notch. Uses the
    /// system `.snappy` spring (macOS 14+) so the transition matches the
    /// timing curve AppKit uses for native tab/segment swaps — quick,
    /// minimal overshoot, no perceptible settle.
    func selectPane(_ pane: NotchPane) {
        guard pane != selectedPane else { return }
        guard let oldIndex = NotchPane.allCases.firstIndex(of: selectedPane),
              let newIndex = NotchPane.allCases.firstIndex(of: pane) else {
            selectedPane = pane
            return
        }
        tabDirection = newIndex > oldIndex ? .forward : .backward
        if pane == .spend {
            usageStore?.refreshNow()
        }
        withAnimation(NotchMotion.tab) {
            selectedPane = pane
        }
    }

    func selectSpendTimeframe(_ timeframe: SpendTimeframe) {
        guard timeframe != selectedSpendTimeframe else { return }
        withAnimation(NotchMotion.tab) {
            selectedSpendTimeframe = timeframe
        }
    }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        isDemoMode = enabled
        UserDefaults.standard.set(enabled, forKey: NotchDemoMode.defaultsKey)

        if enabled, selectedSpendTimeframe != .today {
            withAnimation(NotchMotion.tab) {
                selectedSpendTimeframe = .today
            }
        }
    }

    func collapse() {
        cancelHoverTasks()
        guard isExpanded else { return }
        withAnimation(NotchMotion.morph) {
            isExpanded = false
        }
    }

    /// Activates the terminal that owns the session and dismisses the notch.
    func activate(_ session: AgentSession) {
        TerminalFocusService.focus(session)
        collapse()
    }

    /// Close the terminal window/tab that owns this session. Destructive
    /// process-group termination is only allowed after the row asks the user.
    func closeSession(_ session: AgentSession, allowProcessTermination: Bool = false) {
        TerminalCloseService.close(session, allowProcessTermination: allowProcessTermination)
        // Trigger immediate refresh so the row disappears fast.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sessionStore.refreshNow()
        }
    }

    /// Performs an action on a recent project (open in the preferred terminal /
    /// Finder / GitHub) and dismisses the notch so the user lands directly in
    /// the destination surface.
    func activate(_ project: RecentProject, action: RecentProjectAction) {
        RecentProjectActions.perform(action, project: project)
        collapse()
    }

    /// Called by `GlobalNotchEventMonitor` whenever the cursor crosses into
    /// or out of the notch hover surface. Driven by global mouse position so
    /// it works while the panel has `ignoresMouseEvents = true` (closed) and
    /// SwiftUI's `.onHover` would otherwise see nothing.
    func setHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering

        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            scheduleHoverOpen()
        } else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            scheduleHoverClose()
        }
    }

    // MARK: - Hover scheduling

    private func scheduleHoverOpen() {
        guard !isExpanded else { return }
        recentsStore?.refreshOnDemand()
        usageStore?.refreshNow()
        withAnimation(NotchMotion.morph) {
            isExpanded = true
        }
    }

    private func scheduleHoverClose() {
        guard isExpanded else { return }
        withAnimation(NotchMotion.morph) {
            isExpanded = false
        }
    }

    private func cancelHoverTasks() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask = nil
    }
}

enum NotchDemoMode {
    static let defaultsKey = "notchDemoModeEnabled"

    static func isPersonalProject(_ project: RecentProject) -> Bool {
        !containsShopify(project.path)
            && (project.category.localizedCaseInsensitiveCompare("personal") == .orderedSame
                || isPersonalPath(project.path))
    }

    static func isPersonalSession(_ session: AgentSession) -> Bool {
        isPersonalPath(session.cwd)
    }

    static func demoUsageSnapshots(now: Date = Date(), calendar: Calendar = .current) -> [HarnessUsageSnapshot] {
        let startOfDay = calendar.startOfDay(for: now)
        let elapsedToday = max(now.timeIntervalSince(startOfDay), 60)
        let entries: [DemoSpendEntry] = [
            DemoSpendEntry(
                harness: .codex,
                sessionID: "demo-codex-clanker-1",
                projectName: "clanker",
                cwd: "~/Developer/personal/clanker",
                model: "gpt-5.2-codex",
                tokens: UsageTokenBreakdown(input: 1_940_000, output: 388_000, cacheWrite: 116_000, cacheRead: 2_240_000, reasoningOutput: 142_000, total: 4_826_000),
                costUSD: decimal("286.41")
            ),
            DemoSpendEntry(
                harness: .claude,
                sessionID: "demo-claude-raycast-lab",
                projectName: "raycast-lab",
                cwd: "~/Developer/personal/raycast-lab",
                model: "claude-opus-4.5",
                tokens: UsageTokenBreakdown(input: 1_520_000, output: 276_000, cacheWrite: 84_000, cacheRead: 1_180_000, reasoningOutput: nil, total: 3_060_000),
                costUSD: decimal("214.76")
            ),
            DemoSpendEntry(
                harness: .pi,
                sessionID: "demo-pi-home-dashboard",
                projectName: "home-dashboard",
                cwd: "~/Developer/personal/home-dashboard",
                model: "pi-agent",
                tokens: UsageTokenBreakdown(input: 1_320_000, output: 244_000, cacheWrite: 72_000, cacheRead: 940_000, reasoningOutput: 58_000, total: 2_634_000),
                costUSD: decimal("168.92")
            ),
            DemoSpendEntry(
                harness: .codex,
                sessionID: "demo-codex-clanker-2",
                projectName: "clanker",
                cwd: "~/Developer/personal/clanker",
                model: "gpt-5.2-codex",
                tokens: UsageTokenBreakdown(input: 940_000, output: 166_000, cacheWrite: 44_000, cacheRead: 820_000, reasoningOutput: 64_000, total: 2_034_000),
                costUSD: decimal("136.58")
            ),
            DemoSpendEntry(
                harness: .claude,
                sessionID: "demo-claude-dotfiles",
                projectName: "dotfiles",
                cwd: "~/Developer/personal/dotfiles",
                model: "claude-sonnet-4.5",
                tokens: UsageTokenBreakdown(input: 780_000, output: 128_000, cacheWrite: 36_000, cacheRead: 710_000, reasoningOutput: nil, total: 1_654_000),
                costUSD: decimal("107.29")
            )
        ]

        return entries.enumerated().map { index, entry in
            let position = Double(index + 1) / Double(entries.count + 1)
            let observedAt = startOfDay.addingTimeInterval(elapsedToday * position)
            return HarnessUsageSnapshot(
                id: "demo-\(entry.sessionID)",
                harness: entry.harness,
                sessionID: entry.sessionID,
                projectName: entry.projectName,
                cwd: entry.cwd,
                model: entry.model,
                tokens: entry.tokens,
                costUSD: entry.costUSD,
                costSource: .estimated,
                pricingSource: "Demo Mode",
                observedAt: observedAt,
                sourcePath: nil
            )
        }
    }

    private static func isPersonalPath(_ path: String) -> Bool {
        let components = path
            .lowercased()
            .split(separator: "/")
            .map(String.init)
        return components.contains("personal") && !components.contains("shopify")
    }

    private static func containsShopify(_ path: String) -> Bool {
        path.lowercased()
            .split(separator: "/")
            .contains("shopify")
    }

    private static func decimal(_ value: String) -> Decimal {
        Decimal(string: value) ?? 0
    }

    private struct DemoSpendEntry {
        var harness: HarnessID
        var sessionID: String
        var projectName: String
        var cwd: String
        var model: String
        var tokens: UsageTokenBreakdown
        var costUSD: Decimal
    }
}

struct SessionGroup: Identifiable {
    var title: String
    var sessions: [AgentSession]
    var id: String { title }
}

struct RecentProjectGroup: Identifiable {
    var title: String
    var projects: [RecentProject]
    var id: String { title }

    static func group(_ projects: [RecentProject], now: Date = Date(), calendar: Calendar = .current) -> [RecentProjectGroup] {
        var groups: [RecentProjectGroup] = []
        for project in projects {
            let title = title(for: project.score, now: now, calendar: calendar)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].projects.append(project)
            } else {
                groups.append(RecentProjectGroup(title: title, projects: [project]))
            }
        }
        return groups
    }

    private static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let activityDay = calendar.startOfDay(for: date)
        let daysAgo = max(0, calendar.dateComponents([.day], from: activityDay, to: today).day ?? 0)

        switch daysAgo {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2..<14:
            return "\(daysAgo) days ago"
        case 14..<60:
            let weeks = max(1, daysAgo / 7)
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        case 60..<365:
            let months = max(1, calendar.dateComponents([.month], from: activityDay, to: today).month ?? daysAgo / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        default:
            let years = max(1, calendar.dateComponents([.year], from: activityDay, to: today).year ?? daysAgo / 365)
            return years == 1 ? "1 year ago" : "\(years) years ago"
        }
    }
}

extension Array where Element == AgentSession {
    func sortedForNotch() -> [AgentSession] {
        sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            let lhsActive = lhs.status == .working || lhs.status == .thinking || lhs.status == .runningTool
            let rhsActive = rhs.status == .working || rhs.status == .thinking || rhs.status == .runningTool
            if lhsActive != rhsActive {
                return lhsActive
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }
}

/// Shared motion vocabulary so every transition feels related.
enum NotchMotion {
    /// Container morph — slightly snappy, very low overshoot. Tuned to match
    /// the system Dynamic Island feel.
    static let morph: Animation = .spring(response: 0.30, dampingFraction: 0.78, blendDuration: 0)

    /// Content fade/slide once the morph has settled.
    static let content: Animation = .spring(response: 0.34, dampingFraction: 0.92, blendDuration: 0)

    /// Row insert/remove — a touch springier so list shifts feel alive.
    static let row: Animation = .spring(response: 0.45, dampingFraction: 0.82, blendDuration: 0)

    /// Hover micro-scale; very fast.
    static let hover: Animation = .spring(response: 0.18, dampingFraction: 0.82, blendDuration: 0)

    /// Pane-to-pane swap inside the expanded notch. Apple's pre-tuned
    /// snappy spring — the same one SwiftUI uses for system segmented
    /// controls and `NavigationSplitView` column toggles. Quick (220ms),
    /// barely any overshoot, settles instantly.
    static let tab: Animation = .snappy(duration: 0.22, extraBounce: 0)
}
