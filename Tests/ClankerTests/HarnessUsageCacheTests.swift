import Foundation
import XCTest
@testable import Clanker

final class HarnessUsageCacheTests: XCTestCase {
    func testSnapshotAndMtimeDatesRoundTripWithSecondsSince1970() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let observedAt = Date(timeIntervalSince1970: 1_713_123_456.789)
        let modifiedAt = Date(timeIntervalSince1970: 1_713_123_999.25)
        let sourcePath = "/tmp/clanker-session.jsonl"
        let snapshot = HarnessUsageSnapshot(
            id: "usage-1",
            harness: .codex,
            sessionID: "session-1",
            projectName: "clanker",
            cwd: "/tmp/clanker",
            model: "gpt-test",
            tokens: UsageTokenBreakdown(
                input: 10,
                output: 20,
                cacheWrite: 3,
                cacheRead: 4,
                reasoningOutput: 5,
                total: 42
            ),
            costUSD: Decimal(string: "0.0123"),
            costSource: .estimated,
            pricingSource: "test-pricing",
            observedAt: observedAt,
            sourcePath: sourcePath
        )

        let cache = HarnessUsageCache(cacheDir: cacheDirectory)
        cache.save(snapshots: [snapshot], mtimes: [sourcePath: modifiedAt])

        let loadedSnapshots = cache.load()
        let loadedMtimes = cache.loadMtimes()

        XCTAssertEqual(loadedSnapshots.count, 1)
        XCTAssertEqual(loadedSnapshots.first?.id, snapshot.id)
        XCTAssertEqual(loadedSnapshots.first?.harness, snapshot.harness)
        XCTAssertEqual(loadedSnapshots.first?.tokens, snapshot.tokens)
        XCTAssertEqual(loadedSnapshots.first?.costUSD, snapshot.costUSD)
        let loadedSnapshot = try XCTUnwrap(loadedSnapshots.first)
        XCTAssertEqual(loadedSnapshot.observedAt.timeIntervalSince1970, observedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(loadedMtimes[sourcePath]).timeIntervalSince1970, modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCacheFilesIncludeSchemaVersion() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let cache = HarnessUsageCache(cacheDir: cacheDirectory)
        cache.save(snapshots: [], mtimes: [:])

        let snapshotsData = try Data(contentsOf: cacheDirectory.appendingPathComponent("spend_snapshots.json"))
        let snapshotsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotsData) as? [String: Any])
        XCTAssertEqual(snapshotsJSON["schemaVersion"] as? Int, 1)

        let mtimesData = try Data(contentsOf: cacheDirectory.appendingPathComponent("spend_mtimes.json"))
        let mtimesJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: mtimesData) as? [String: Any])
        XCTAssertEqual(mtimesJSON["schemaVersion"] as? Int, 1)
    }
}
