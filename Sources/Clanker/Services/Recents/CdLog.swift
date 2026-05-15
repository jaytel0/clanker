import Foundation

/// Reads the `chpwd` log produced by `CdHookInstaller`'s shell hook.
///
/// The log is append-only `<unix_ts>\t<absolute_path>\n` and may grow
/// unbounded over time, so we only ever read the tail (~256 KB ≈ tens of
/// thousands of recent cd events) and trim periodically.
enum CdLog {
    static var logURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Clanker", isDirectory: true)
            .appendingPathComponent("cd-log.tsv", isDirectory: false)
    }

    private static let tailBytes: UInt64 = 256 * 1024
    /// Trim the log on disk when it exceeds this size, keeping the most
    /// recent `tailBytes` worth of events. Cheap insurance against runaway
    /// growth on long-lived machines.
    private static let maxBytesBeforeTrim: UInt64 = 4 * 1024 * 1024

    /// Returns `path → most recent cd timestamp` from the tail of the log.
    /// Empty if the log doesn't exist (hook not installed yet, or never cd'd).
    static func mostRecentByPath() -> [String: Date] {
        let url = logURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return [:] }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return [:] }

        // If we sliced into the middle of a line, drop the partial leading line.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        var result: [String: Date] = [:]
        result.reserveCapacity(256)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Format: "<unix_ts>\t<path>". Path can contain spaces, so split
            // exactly once on the first tab and keep the rest verbatim.
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let tsSlice = line[..<tab]
            let pathSlice = line[line.index(after: tab)...]
            guard let ts = TimeInterval(tsSlice), !pathSlice.isEmpty else { continue }
            let path = String(pathSlice)
            let date = Date(timeIntervalSince1970: ts)
            if let existing = result[path], existing >= date { continue }
            result[path] = date
        }

        // Best-effort tail trim if the file has grown well beyond the read
        // window. Don't block on failures — losing a trim is harmless.
        if size > maxBytesBeforeTrim {
            try? trimToTail(url: url, keepBytes: tailBytes)
        }

        return result
    }

    private static func trimToTail(url: URL, keepBytes: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > keepBytes else { return }
        try handle.seek(toOffset: size - keepBytes)
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else { return }

        // Drop any partial leading line so the trimmed file always starts on
        // a record boundary.
        var trimmed = data
        if let newlineIdx = data.firstIndex(of: 0x0A) {
            trimmed = data.subdata(in: (newlineIdx + 1)..<data.endIndex)
        }
        try trimmed.write(to: url, options: .atomic)
    }
}
