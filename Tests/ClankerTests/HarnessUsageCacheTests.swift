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

    func testLoadsLegacyRawCacheFilesWithSecondsSince1970Dates() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let observedAt = Date(timeIntervalSince1970: 1_713_222_333.5)
        let modifiedAt = Date(timeIntervalSince1970: 1_713_222_444.25)
        let sourcePath = "/tmp/legacy-clanker-session.jsonl"
        let snapshotPayload: [[String: Any]] = [[
            "id": "legacy-usage-1",
            "harness": "pi",
            "sessionID": "legacy-session-1",
            "projectName": "legacy",
            "cwd": "/tmp/legacy",
            "tokensInput": 11,
            "tokensOutput": 22,
            "tokensTotal": 33,
            "costUSD": "0.0456",
            "costSource": "reported",
            "observedAt": observedAt.timeIntervalSince1970,
            "sourcePath": sourcePath
        ]]
        let mtimesPayload: [String: Any] = [
            sourcePath: modifiedAt.timeIntervalSince1970
        ]

        try JSONSerialization.data(withJSONObject: snapshotPayload)
            .write(to: cacheDirectory.appendingPathComponent("spend_snapshots.json"))
        try JSONSerialization.data(withJSONObject: mtimesPayload)
            .write(to: cacheDirectory.appendingPathComponent("spend_mtimes.json"))

        let cache = HarnessUsageCache(cacheDir: cacheDirectory)
        let loadedSnapshot = try XCTUnwrap(cache.load().first)
        let loadedMtime = try XCTUnwrap(cache.loadMtimes()[sourcePath])

        XCTAssertEqual(loadedSnapshot.id, "legacy-usage-1")
        XCTAssertEqual(loadedSnapshot.harness, .pi)
        XCTAssertEqual(loadedSnapshot.tokens.total, 33)
        XCTAssertEqual(loadedSnapshot.costUSD, Decimal(string: "0.0456"))
        XCTAssertEqual(loadedSnapshot.observedAt.timeIntervalSince1970, observedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loadedMtime.timeIntervalSince1970, modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }
}
