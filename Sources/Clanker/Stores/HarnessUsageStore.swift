import Combine
import Foundation

@MainActor
final class HarnessUsageStore: ObservableObject {
    @Published private(set) var snapshots: [HarnessUsageSnapshot] = []

    private var timer: Timer?
    private var isRefreshing = false
    private var hasLoadedOnce = false
    private let configuration: HarnessUsageScanConfiguration
    private let cache = HarnessUsageCache()

    init(configuration: HarnessUsageScanConfiguration = .default) {
        self.configuration = configuration
    }

    /// Call on app launch. Does NOT scan — just loads the disk cache so the
    /// Spend tab can show stale-but-instant data if the user opens it before
    /// the first real scan.
    func start() {
        let cached = cache.load()
        if !cached.isEmpty {
            snapshots = cached
            hasLoadedOnce = true
        }
    }

    /// Trigger a scan now. Called lazily the first time the user opens the
    /// Spend tab, and on subsequent notch expansions.
    func refreshNow() {
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let configuration = configuration
        let cache = cache
        let previousMtimes = cache.loadMtimes()
        let cachedSnapshots = snapshots

        Task.detached(priority: .utility) {
            let result = HarnessUsageScanner.incrementalScan(
                configuration: configuration,
                previousMtimes: previousMtimes,
                cachedSnapshots: cachedSnapshots
            )
            await MainActor.run {
                self.snapshots = result.snapshots
                self.hasLoadedOnce = true
                self.isRefreshing = false
            }
            // Persist off main thread
            cache.save(snapshots: result.snapshots, mtimes: result.mtimes)
        }
    }
}

// MARK: - Disk cache

/// Lightweight disk cache that persists computed snapshots and file mtimes
/// so subsequent launches skip unchanged files entirely.
private final class HarnessUsageCache: Sendable {
    private let cacheDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clanker/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var snapshotsCacheURL: URL { cacheDir.appendingPathComponent("spend_snapshots.json") }
    private var mtimesCacheURL: URL { cacheDir.appendingPathComponent("spend_mtimes.json") }

    func load() -> [HarnessUsageSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsCacheURL),
              let decoded = try? JSONDecoder().decode([CachedSnapshot].self, from: data) else {
            return []
        }
        return decoded.map(\.toSnapshot)
    }

    func loadMtimes() -> [String: Date] {
        guard let data = try? Data(contentsOf: mtimesCacheURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func save(snapshots: [HarnessUsageSnapshot], mtimes: [String: Date]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(snapshots.map(CachedSnapshot.init)) {
            try? data.write(to: snapshotsCacheURL, options: .atomic)
        }
        if let data = try? encoder.encode(mtimes) {
            try? data.write(to: mtimesCacheURL, options: .atomic)
        }
    }
}

/// Codable projection of `HarnessUsageSnapshot` for disk caching.
private struct CachedSnapshot: Codable {
    var id: String
    var harness: String
    var sessionID: String
    var projectName: String
    var cwd: String
    var model: String?
    var tokensInput: Int?
    var tokensOutput: Int?
    var tokensCacheWrite: Int?
    var tokensCacheRead: Int?
    var tokensReasoningOutput: Int?
    var tokensTotal: Int?
    var costUSD: String?
    var costSource: String
    var pricingSource: String?
    var observedAt: Date
    var sourcePath: String?

    init(_ s: HarnessUsageSnapshot) {
        id = s.id
        harness = s.harness.rawValue
        sessionID = s.sessionID
        projectName = s.projectName
        cwd = s.cwd
        model = s.model
        tokensInput = s.tokens.input
        tokensOutput = s.tokens.output
        tokensCacheWrite = s.tokens.cacheWrite
        tokensCacheRead = s.tokens.cacheRead
        tokensReasoningOutput = s.tokens.reasoningOutput
        tokensTotal = s.tokens.total
        costUSD = s.costUSD.map { NSDecimalNumber(decimal: $0).stringValue }
        costSource = s.costSource.rawValue
        pricingSource = s.pricingSource
        observedAt = s.observedAt
        sourcePath = s.sourcePath
    }

    var toSnapshot: HarnessUsageSnapshot {
        HarnessUsageSnapshot(
            id: id,
            harness: HarnessID(rawValue: harness) ?? .terminal,
            sessionID: sessionID,
            projectName: projectName,
            cwd: cwd,
            model: model,
            tokens: UsageTokenBreakdown(
                input: tokensInput,
                output: tokensOutput,
                cacheWrite: tokensCacheWrite,
                cacheRead: tokensCacheRead,
                reasoningOutput: tokensReasoningOutput,
                total: tokensTotal
            ),
            costUSD: costUSD.flatMap { Decimal(string: $0) },
            costSource: UsageCostSource(rawValue: costSource) ?? .unknown,
            pricingSource: pricingSource,
            observedAt: observedAt,
            sourcePath: sourcePath
        )
    }
}
