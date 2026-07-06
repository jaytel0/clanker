import Foundation

enum DiscoveryHelpers {
    static func normalizedTTY(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        if trimmed.hasPrefix("tty") { return "/dev/\(trimmed)" }
        return "/dev/tty\(trimmed)"
    }

    static func normalizedPath(_ path: String) -> String {
        let expanded = expandHome(path)
        let standardized = (expanded as NSString).standardizingPath
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    static func expandHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }

    static func isUsefulPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "/" && trimmed != "~" && trimmed != NSHomeDirectory()
    }

    static func projectName(for cwd: String) -> String {
        let expanded = expandHome(cwd)
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        return name.isEmpty ? expanded : name
    }

    static func abbreviateHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func identifierSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/dev/", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func recentJSONLFiles(at root: URL, maxAge: TimeInterval, limit: Int) -> [(URL, Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-maxAge)
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile != false,
                      let modified = values?.contentModificationDate,
                      modified >= cutoff else {
                    return nil
                }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    static func readUTF8File(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    static func readTail(_ url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0 {
            // Drop the partial first line at the byte level BEFORE decoding:
            // the cut can land mid multi-byte UTF-8 character, and decoding
            // the raw tail would fail outright for any transcript containing
            // non-ASCII near the boundary.
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            } else {
                return ""
            }
        }
        return String(data: data, encoding: .utf8)
    }

    static func jsonObject(fromLine line: Substring) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let raw = value as? Double {
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = string(value) else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }

        return ISO8601DateFormatter().date(from: text)
    }

    static func compactText(_ value: Any?) -> String? {
        if let text = string(value) {
            return truncated(text, limit: 160)
        }
        if let array = value as? [Any] {
            let text = array.compactMap(compactText).joined(separator: "\n")
            return text.nonEmpty.map { truncated($0, limit: 160) }
        }
        if let object = value as? [String: Any] {
            return compactText(object["text"] ?? object["content"] ?? object["message"])
        }
        return nil
    }

    static func messageText(_ message: [String: Any]) -> String? {
        if let text = string(message["content"]) {
            return truncated(text, limit: 160)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                if let text = string(block["text"]) { return text }
                if let content = string(block["content"]) { return content }
                return nil
            }.joined(separator: "\n")
            return text.nonEmpty.map { truncated($0, limit: 160) }
        }
        return nil
    }

    static func userFacingMessageText(_ message: [String: Any]) -> String? {
        guard let text = messageText(message) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<skill "),
              !trimmed.hasPrefix("<skill-name>"),
              !trimmed.hasPrefix("<system-reminder>"),
              !trimmed.hasPrefix("<command-name>") else {
            return nil
        }
        return trimmed
    }

    static func normalizedToolName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func truncated(_ value: String, limit: Int) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - File parse caching

/// Caches the parsed form of a file, invalidated by (mtime, size). Transcript
/// scans hit dozens of multi-megabyte JSONL files; almost none change between
/// ticks, so re-parsing only the changed ones turns the recurring scan cost
/// from "read everything" into "stat everything".
final class FileParseCache<Value: Sendable>: @unchecked Sendable {
    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    private struct Entry {
        var stamp: Stamp
        var value: Value?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Returns the cached parse when the file is unchanged; otherwise runs
    /// `parse` and caches its result (including `nil`, so unparseable files
    /// aren't re-read every tick).
    func value(for url: URL, parse: (URL) -> Value?) -> Value? {
        let key = url.path
        let stamp = currentStamp(for: url)

        lock.lock()
        if let entry = entries[key], let stamp, entry.stamp == stamp {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = parse(url)

        if let stamp {
            lock.lock()
            entries[key] = Entry(stamp: stamp, value: value)
            // Bound the cache: transcript directories accumulate thousands of
            // files over months; only the recent window matters.
            if entries.count > 512 {
                let stale = entries.keys.prefix(entries.count - 384)
                for key in stale { entries.removeValue(forKey: key) }
            }
            lock.unlock()
        }
        return value
    }

    private func currentStamp(for url: URL) -> Stamp? {
        // FileManager, not URL.resourceValues — NSURL caches resource values
        // per instance, which would freeze the stamp for repeated lookups.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return Stamp(modified: modified, size: size)
    }
}
