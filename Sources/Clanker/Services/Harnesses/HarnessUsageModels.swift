import Foundation

enum UsageCostSource: String, Sendable {
    case reported
    case estimated
    case quotaOnly
    case unknown

    var title: String {
        switch self {
        case .reported: "Reported"
        case .estimated: "Estimated"
        case .quotaOnly: "Tokens"
        case .unknown: "Unknown"
        }
    }

    static func merged(_ sources: [UsageCostSource]) -> UsageCostSource {
        if sources.contains(.estimated) { return .estimated }
        if sources.contains(.reported) { return .reported }
        if sources.contains(.quotaOnly) { return .quotaOnly }
        return .unknown
    }
}

struct UsageTokenBreakdown: Equatable, Sendable {
    var input: Int?
    var output: Int?
    var cacheWrite: Int?
    var cacheRead: Int?
    var reasoningOutput: Int?
    var total: Int?

    var knownTotal: Int {
        if let total { return total }
        return [input, output, cacheWrite, cacheRead, reasoningOutput]
            .compactMap { $0 }
            .reduce(0, +)
    }

    mutating func add(_ other: UsageTokenBreakdown) {
        let combinedTotal = knownTotal + other.knownTotal
        input = summed(input, other.input)
        output = summed(output, other.output)
        cacheWrite = summed(cacheWrite, other.cacheWrite)
        cacheRead = summed(cacheRead, other.cacheRead)
        reasoningOutput = summed(reasoningOutput, other.reasoningOutput)
        total = combinedTotal > 0 ? combinedTotal : nil
    }

    func subtracting(_ other: UsageTokenBreakdown) -> UsageTokenBreakdown {
        UsageTokenBreakdown(
            input: difference(input, other.input),
            output: difference(output, other.output),
            cacheWrite: difference(cacheWrite, other.cacheWrite),
            cacheRead: difference(cacheRead, other.cacheRead),
            reasoningOutput: difference(reasoningOutput, other.reasoningOutput),
            total: difference(total, other.total)
        )
    }

    private func summed(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs + rhs
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private func difference(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs else { return nil }
        return max(0, lhs - (rhs ?? 0))
    }
}

struct HarnessUsageSnapshot: Identifiable, Equatable, Sendable {
    var id: String
    var harness: HarnessID
    var sessionID: String
    var projectName: String
    var cwd: String
    var model: String?
    var tokens: UsageTokenBreakdown
    var costUSD: Decimal?
    var costSource: UsageCostSource
    var pricingSource: String?
    var observedAt: Date
    var sourcePath: String?

    var hasSpendSignal: Bool {
        costUSD != nil || tokens.knownTotal > 0
    }
}

enum SpendTimeframe: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        }
    }

    var shortLabel: String {
        switch self {
        case .today: "1d"
        case .last7Days: "7d"
        case .last30Days: "1m"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        date >= startDate(now: now, calendar: calendar)
    }

    private func startDate(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

struct SpendBreakdownItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var harness: HarnessID?
    var tokens: UsageTokenBreakdown
    var costUSD: Decimal?
    var costSource: UsageCostSource
    var snapshotCount: Int
    var lastObservedAt: Date
}

struct SpendSummary: Equatable, Sendable {
    var timeframe: SpendTimeframe
    var snapshots: [HarnessUsageSnapshot]
    var totalCostUSD: Decimal?
    var totalTokens: Int
    var costSource: UsageCostSource
    var byHarness: [SpendBreakdownItem]
    var byProject: [SpendBreakdownItem]

    init(
        snapshots: [HarnessUsageSnapshot],
        timeframe: SpendTimeframe = .last30Days,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.timeframe = timeframe
        let usableSnapshots = snapshots
            .filter(\.hasSpendSignal)
            .filter { timeframe.contains($0.observedAt, now: now, calendar: calendar) }
        self.snapshots = usableSnapshots
        totalCostUSD = Self.sumCost(usableSnapshots)
        totalTokens = usableSnapshots.map(\.tokens.knownTotal).reduce(0, +)
        costSource = UsageCostSource.merged(usableSnapshots.map(\.costSource))
        byHarness = Self.breakdownByHarness(usableSnapshots)
        byProject = Self.breakdownByProject(usableSnapshots)
    }

    private static func breakdownByHarness(_ snapshots: [HarnessUsageSnapshot]) -> [SpendBreakdownItem] {
        Dictionary(grouping: snapshots, by: \.harness)
            .map { harness, snapshots in
                let tokens = sumTokens(snapshots)
                return SpendBreakdownItem(
                    id: "harness-\(harness.rawValue)",
                    title: harness.displayName,
                    subtitle: "\(snapshots.count) \(snapshots.count == 1 ? "event" : "events")",
                    harness: harness,
                    tokens: tokens,
                    costUSD: sumCost(snapshots),
                    costSource: UsageCostSource.merged(snapshots.map(\.costSource)),
                    snapshotCount: snapshots.count,
                    lastObservedAt: snapshots.map(\.observedAt).max() ?? .distantPast
                )
            }
            .sorted(by: sortBreakdown)
    }

    private static func breakdownByProject(_ snapshots: [HarnessUsageSnapshot]) -> [SpendBreakdownItem] {
        Dictionary(grouping: snapshots, by: \.projectName)
            .map { projectName, snapshots in
                let tokens = sumTokens(snapshots)
                let harnesses = snapshots
                    .map(\.harness.displayName)
                    .uniqued()
                    .prefix(3)
                    .joined(separator: ", ")
                return SpendBreakdownItem(
                    id: "project-\(projectName)",
                    title: projectName,
                    subtitle: harnesses.isEmpty ? "\(snapshots.count) events" : harnesses,
                    harness: nil,
                    tokens: tokens,
                    costUSD: sumCost(snapshots),
                    costSource: UsageCostSource.merged(snapshots.map(\.costSource)),
                    snapshotCount: snapshots.count,
                    lastObservedAt: snapshots.map(\.observedAt).max() ?? .distantPast
                )
            }
            .sorted(by: sortBreakdown)
    }

    private static func sumTokens(_ snapshots: [HarnessUsageSnapshot]) -> UsageTokenBreakdown {
        snapshots.reduce(into: UsageTokenBreakdown()) { partial, snapshot in
            partial.add(snapshot.tokens)
        }
    }

    private static func sumCost(_ snapshots: [HarnessUsageSnapshot]) -> Decimal? {
        let values = snapshots.compactMap(\.costUSD)
        guard !values.isEmpty else { return nil }
        return values.reduce(Decimal(0), +)
    }

    private static func sortBreakdown(_ lhs: SpendBreakdownItem, _ rhs: SpendBreakdownItem) -> Bool {
        switch (lhs.costUSD, rhs.costUSD) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.tokens.knownTotal != rhs.tokens.knownTotal {
                return lhs.tokens.knownTotal > rhs.tokens.knownTotal
            }
            return lhs.lastObservedAt > rhs.lastObservedAt
        }
    }
}

enum SpendFormatting {
    static func cost(_ value: Decimal?) -> String {
        guard let value else { return "Unknown" }
        let doubleValue = NSDecimalNumber(decimal: value).doubleValue
        if doubleValue > 0, doubleValue < 0.01 {
            return String(format: "$%.3f", doubleValue)
        }
        return String(format: "$%.2f", doubleValue)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
