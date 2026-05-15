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
        input = summed(input, other.input)
        output = summed(output, other.output)
        cacheWrite = summed(cacheWrite, other.cacheWrite)
        cacheRead = summed(cacheRead, other.cacheRead)
        reasoningOutput = summed(reasoningOutput, other.reasoningOutput)
        total = summed(total, other.total)
    }

    private func summed(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs + rhs
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
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
    var snapshots: [HarnessUsageSnapshot]
    var totalCostUSD: Decimal?
    var totalTokens: Int
    var costSource: UsageCostSource
    var byHarness: [SpendBreakdownItem]
    var byProject: [SpendBreakdownItem]

    init(snapshots: [HarnessUsageSnapshot]) {
        let usableSnapshots = snapshots.filter(\.hasSpendSignal)
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
                    subtitle: "\(snapshots.count) \(snapshots.count == 1 ? "session" : "sessions")",
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
                    subtitle: harnesses.isEmpty ? "\(snapshots.count) sessions" : harnesses,
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
