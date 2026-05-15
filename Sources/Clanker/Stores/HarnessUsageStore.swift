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
final class HarnessUsageCache: Sendable {
    private static let schemaVersion = 1

    private let cacheDir: URL

    init(cacheDir: URL = HarnessUsageCache.defaultCacheDirectory()) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private var snapshotsCacheURL: URL { cacheDir.appendingPathComponent("spend_snapshots.json") }
    private var mtimesCacheURL: URL { cacheDir.appendingPathComponent("spend_mtimes.json") }

    func load() -> [HarnessUsageSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsCacheURL),
              let decoded = decodeSnapshots(from: data) else {
            return []
        }
        return decoded.map(\.toSnapshot)
    }

    func loadMtimes() -> [String: Date] {
        guard let data = try? Data(contentsOf: mtimesCacheURL),
              let decoded = decodeMtimes(from: data) else {
            return [:]
        }
        return decoded
    }

    func save(snapshots: [HarnessUsageSnapshot], mtimes: [String: Date]) {
        let encoder = Self.makeEncoder()
        let snapshotsFile = CachedSnapshotsFile(
            schemaVersion: Self.schemaVersion,
            snapshots: snapshots.map(CachedSnapshot.init)
        )
        if let data = try? encoder.encode(snapshotsFile) {
            try? data.write(to: snapshotsCacheURL, options: .atomic)
        }
        let mtimesFile = CachedMtimesFile(
            schemaVersion: Self.schemaVersion,
            mtimes: mtimes
        )
        if let data = try? encoder.encode(mtimesFile) {
            try? data.write(to: mtimesCacheURL, options: .atomic)
        }
    }

    private static func defaultCacheDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clanker/cache", isDirectory: true)
    }

    private func decodeSnapshots(from data: Data) -> [CachedSnapshot]? {
        let decoder = Self.makeDecoder()
        if let file = try? decoder.decode(CachedSnapshotsFile.self, from: data),
           file.schemaVersion == Self.schemaVersion {
            return file.snapshots
        }

        return try? decoder.decode([CachedSnapshot].self, from: data)
    }

    private func decodeMtimes(from data: Data) -> [String: Date]? {
        let decoder = Self.makeDecoder()
        if let file = try? decoder.decode(CachedMtimesFile.self, from: data),
           file.schemaVersion == Self.schemaVersion {
            return file.mtimes
        }

        return try? decoder.decode([String: Date].self, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

private struct CachedSnapshotsFile: Codable {
    var schemaVersion: Int
    var snapshots: [CachedSnapshot]
}

private struct CachedMtimesFile: Codable {
    var schemaVersion: Int
    var mtimes: [String: Date]
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
