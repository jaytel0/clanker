import XCTest
@testable import Clanker

final class CodexSessionIndexTests: XCTestCase {
    func testParsesThreadNamesAndPrefersLatestEntry() throws {
        let jsonl = """
        {"id":"thread-1","thread_name":"Analyze repo","updated_at":"2026-06-20T19:19:51Z"}
        {"id":"thread-2","thread_name":"Old name","updated_at":"2026-06-20T19:20:00Z"}
        {"id":"thread-2","thread_name":"Renamed task","updated_at":"2026-06-21T09:00:00Z"}
        not json
        {"id":"thread-3"}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-index-\(UUID().uuidString).jsonl")
        try jsonl.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let names = try XCTUnwrap(CodexSessionIndex.parse(url))
        XCTAssertEqual(names["thread-1"], "Analyze repo")
        XCTAssertEqual(names["thread-2"], "Renamed task")
        XCTAssertNil(names["thread-3"])
    }
}

final class ReadTailTests: XCTestCase {
    func testTailCutMidMultibyteCharacterStillDecodes() throws {
        // Build a file where the byte-offset cut lands inside a multi-byte
        // character ("…" is 3 bytes). The partial first line must be dropped
        // at the byte level or the whole decode fails.
        var content = ""
        for index in 0..<50 {
            content += "line \(index) ……………………………………\n"
        }
        content += "final line\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).txt")
        try content.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for maxBytes in UInt64(20)...UInt64(80) {
            let tail = DiscoveryHelpers.readTail(url, maxBytes: maxBytes)
            XCTAssertNotNil(tail, "decode failed for maxBytes=\(maxBytes)")
            if let tail, !tail.isEmpty {
                XCTAssertTrue(tail.hasSuffix("final line\n"))
            }
        }
    }

    func testWholeFileReadKeepsFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).txt")
        try "first\nsecond\n".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(DiscoveryHelpers.readTail(url, maxBytes: 1024), "first\nsecond\n")
    }
}

final class FileParseCacheTests: XCTestCase {
    func testReparsesOnlyWhenFileChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).txt")
        try "one".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = FileParseCache<String>()
        var parseCount = 0
        let parse: (URL) -> String? = { url in
            parseCount += 1
            return try? String(contentsOf: url, encoding: .utf8)
        }

        XCTAssertEqual(cache.value(for: url, parse: parse), "one")
        XCTAssertEqual(cache.value(for: url, parse: parse), "one")
        XCTAssertEqual(parseCount, 1)

        // Rewrite with different content *and* size; mtime alone can be
        // too coarse within the same filesystem timestamp granularity.
        try "two-changed".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(cache.value(for: url, parse: parse), "two-changed")
        XCTAssertEqual(parseCount, 2)
    }

    func testMissingFileIsNotCached() {
        let cache = FileParseCache<String>()
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        var parseCount = 0
        _ = cache.value(for: missing) { _ in
            parseCount += 1
            return nil
        }
        _ = cache.value(for: missing) { _ in
            parseCount += 1
            return nil
        }
        // No stamp -> nothing cached -> parse runs each time (cheap no-op).
        XCTAssertEqual(parseCount, 2)
    }
}
