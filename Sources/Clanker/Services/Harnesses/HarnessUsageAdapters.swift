import Foundation

protocol HarnessUsageAdapter: Sendable {
    var harness: HarnessID { get }
    func scan(configuration: HarnessUsageScanConfiguration) -> [HarnessUsageSnapshot]
}

struct HarnessUsageScanConfiguration: Sendable {
    var maxAge: TimeInterval
    var limitPerAdapter: Int
    var maxFileBytes: Int

    static let `default` = HarnessUsageScanConfiguration(
        maxAge: 30 * 24 * 60 * 60,
        limitPerAdapter: 200,
        maxFileBytes: 16 * 1024 * 1024
    )
}

enum HarnessUsageRegistry {
    static let adapters: [any HarnessUsageAdapter] = [
        PiUsageAdapter(),
        ClaudeCodeUsageAdapter(),
        CodexUsageAdapter()
    ]
}

enum HarnessUsageScanner {
    static func scan(configuration: HarnessUsageScanConfiguration = .default) -> [HarnessUsageSnapshot] {
        let snapshots = HarnessUsageRegistry.adapters.flatMap {
            $0.scan(configuration: configuration)
        }

        return snapshots
            .reduce(into: [String: HarnessUsageSnapshot]()) { partial, snapshot in
                guard snapshot.hasSpendSignal else { return }
                if let existing = partial[snapshot.id],
                   existing.observedAt > snapshot.observedAt {
                    return
                }
                partial[snapshot.id] = snapshot
            }
            .values
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt {
                    return lhs.observedAt > rhs.observedAt
                }
                return lhs.id < rhs.id
            }
    }
}

struct PiUsageAdapter: HarnessUsageAdapter {
    let harness: HarnessID = .pi

    func scan(configuration: HarnessUsageScanConfiguration) -> [HarnessUsageSnapshot] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        return HarnessUsageFileHelpers.recentJSONLFiles(
            at: root,
            maxAge: configuration.maxAge,
            limit: configuration.limitPerAdapter
        )
        .compactMap { parse(file: $0.0, modified: $0.1, maxBytes: configuration.maxFileBytes) }
    }

    private func parse(file: URL, modified: Date, maxBytes: Int) -> HarnessUsageSnapshot? {
        guard let content = HarnessUsageFileHelpers.readUTF8File(file, maxBytes: maxBytes) else {
            return nil
        }

        var sessionID = file.deletingPathExtension().lastPathComponent
        var cwd: String?
        var observedAt = modified
        var modelWeights: [String: Decimal] = [:]
        var tokens = UsageTokenBreakdown()
        var totalCost = Decimal(0)
        var hasReportedCost = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = HarnessUsageJSON.object(fromLine: line) else { continue }
            observedAt = max(observedAt, HarnessUsageJSON.date(json["timestamp"]) ?? observedAt)

            switch HarnessUsageJSON.string(json["type"]) {
            case "session":
                sessionID = HarnessUsageJSON.string(json["id"]) ?? sessionID
                cwd = HarnessUsageJSON.string(json["cwd"]) ?? cwd
            case "message":
                guard let message = json["message"] as? [String: Any],
                      HarnessUsageJSON.string(message["role"]) == "assistant",
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                let turnTokens = HarnessUsageJSON.tokens(from: usage)
                tokens.add(turnTokens)

                let cost = (usage["cost"] as? [String: Any])
                    .flatMap { HarnessUsageJSON.decimal($0["total"]) }
                if let cost {
                    totalCost += cost
                    hasReportedCost = true
                    if let model = HarnessUsageJSON.string(message["model"]) {
                        modelWeights[model, default: 0] += cost
                    }
                } else if let model = HarnessUsageJSON.string(message["model"]) {
                    modelWeights[model, default: 0] += Decimal(turnTokens.knownTotal)
                }
            default:
                break
            }
        }

        guard tokens.knownTotal > 0 || hasReportedCost else { return nil }

        let cwdValue = cwd ?? decodeProjectPath(file.deletingLastPathComponent().lastPathComponent)
        let model = modelWeights.max { lhs, rhs in lhs.value < rhs.value }?.key
        return HarnessUsageSnapshot(
            id: "pi-\(sessionID)",
            harness: harness,
            sessionID: sessionID,
            projectName: HarnessUsageFileHelpers.projectName(for: cwdValue),
            cwd: HarnessUsageFileHelpers.abbreviateHome(cwdValue),
            model: model,
            tokens: tokens,
            costUSD: hasReportedCost ? totalCost : nil,
            costSource: hasReportedCost ? .reported : .quotaOnly,
            pricingSource: hasReportedCost ? "Pi usage.cost.total" : nil,
            observedAt: observedAt,
            sourcePath: file.path
        )
    }

    private func decodeProjectPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }
}

struct ClaudeCodeUsageAdapter: HarnessUsageAdapter {
    let harness: HarnessID = .claude

    func scan(configuration: HarnessUsageScanConfiguration) -> [HarnessUsageSnapshot] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        return HarnessUsageFileHelpers.recentJSONLFiles(
            at: root,
            maxAge: configuration.maxAge,
            limit: configuration.limitPerAdapter
        )
        .compactMap { parse(file: $0.0, modified: $0.1, maxBytes: configuration.maxFileBytes) }
    }

    private func parse(file: URL, modified: Date, maxBytes: Int) -> HarnessUsageSnapshot? {
        guard let content = HarnessUsageFileHelpers.readUTF8File(file, maxBytes: maxBytes) else {
            return nil
        }

        var sessionID = file.deletingPathExtension().lastPathComponent
        var cwd: String?
        var observedAt = modified
        var modelWeights: [String: Decimal] = [:]
        var tokens = UsageTokenBreakdown()
        var seenUsageIDs = Set<String>()

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = HarnessUsageJSON.object(fromLine: line),
                  HarnessUsageJSON.string(json["type"]) == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            let usageID = HarnessUsageJSON.string(message["id"])
                ?? HarnessUsageJSON.string(json["requestId"])
                ?? HarnessUsageJSON.string(json["uuid"])
            if let usageID, !seenUsageIDs.insert(usageID).inserted {
                continue
            }

            sessionID = HarnessUsageJSON.string(json["sessionId"]) ?? sessionID
            cwd = HarnessUsageJSON.string(json["cwd"]) ?? cwd
            observedAt = max(observedAt, HarnessUsageJSON.date(json["timestamp"]) ?? observedAt)

            let turnTokens = HarnessUsageJSON.tokens(from: usage)
            tokens.add(turnTokens)
            if let model = HarnessUsageJSON.string(message["model"]) {
                modelWeights[model, default: 0] += Decimal(turnTokens.knownTotal)
            }
        }

        guard tokens.knownTotal > 0 else { return nil }

        let cwdValue = cwd ?? decodeProjectSlug(file.deletingLastPathComponent().lastPathComponent)
        let model = modelWeights.max { lhs, rhs in lhs.value < rhs.value }?.key
        let estimate = UsagePricingCatalog.estimateCost(provider: "anthropic", model: model, tokens: tokens)
        return HarnessUsageSnapshot(
            id: "claude-\(sessionID)",
            harness: harness,
            sessionID: sessionID,
            projectName: HarnessUsageFileHelpers.projectName(for: cwdValue),
            cwd: HarnessUsageFileHelpers.abbreviateHome(cwdValue),
            model: model,
            tokens: tokens,
            costUSD: estimate?.costUSD,
            costSource: estimate == nil ? .quotaOnly : .estimated,
            pricingSource: estimate?.pricingSource,
            observedAt: observedAt,
            sourcePath: file.path
        )
    }

    private func decodeProjectSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        return "/" + trimmed.split(separator: "-").joined(separator: "/")
    }
}

struct CodexUsageAdapter: HarnessUsageAdapter {
    let harness: HarnessID = .codex

    func scan(configuration: HarnessUsageScanConfiguration) -> [HarnessUsageSnapshot] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        return HarnessUsageFileHelpers.recentJSONLFiles(
            at: root,
            maxAge: configuration.maxAge,
            limit: configuration.limitPerAdapter
        )
        .filter { $0.0.lastPathComponent.hasPrefix("rollout-") }
        .compactMap { parse(file: $0.0, modified: $0.1, maxBytes: configuration.maxFileBytes) }
    }

    private func parse(file: URL, modified: Date, maxBytes: Int) -> HarnessUsageSnapshot? {
        guard let content = HarnessUsageFileHelpers.readUTF8File(file, maxBytes: maxBytes) else {
            return nil
        }

        var sessionID = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "rollout-", with: "")
        var cwd = NSHomeDirectory()
        var model: String?
        var observedAt = modified
        var totalTokens: UsageTokenBreakdown?

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = HarnessUsageJSON.object(fromLine: line) else { continue }
            observedAt = max(observedAt, HarnessUsageJSON.date(json["timestamp"]) ?? observedAt)

            switch HarnessUsageJSON.string(json["type"]) {
            case "session_meta":
                let payload = json["payload"] as? [String: Any] ?? [:]
                sessionID = HarnessUsageJSON.string(payload["id"]) ?? sessionID
                cwd = HarnessUsageJSON.string(payload["cwd"]) ?? cwd
                model = HarnessUsageJSON.string(payload["model"]) ?? model
            case "turn_context":
                let payload = json["payload"] as? [String: Any] ?? [:]
                cwd = HarnessUsageJSON.string(payload["cwd"]) ?? cwd
                model = HarnessUsageJSON.string(payload["model"]) ?? model
            case "event_msg":
                let payload = json["payload"] as? [String: Any] ?? [:]
                guard HarnessUsageJSON.string(payload["type"]) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any] else {
                    continue
                }
                totalTokens = HarnessUsageJSON.tokens(from: usage)
            default:
                break
            }
        }

        guard let tokens = totalTokens, tokens.knownTotal > 0 else { return nil }

        let estimate = UsagePricingCatalog.estimateCost(provider: "openai", model: model, tokens: tokens)
        return HarnessUsageSnapshot(
            id: "codex-\(sessionID)",
            harness: harness,
            sessionID: sessionID,
            projectName: HarnessUsageFileHelpers.projectName(for: cwd),
            cwd: HarnessUsageFileHelpers.abbreviateHome(cwd),
            model: model,
            tokens: tokens,
            costUSD: estimate?.costUSD,
            costSource: estimate == nil ? .quotaOnly : .estimated,
            pricingSource: estimate?.pricingSource,
            observedAt: observedAt,
            sourcePath: file.path
        )
    }
}

struct UsageCostEstimate: Sendable {
    var costUSD: Decimal
    var pricingSource: String
}

enum UsagePricingCatalog {
    private struct Rates {
        var inputPerMillion: Decimal
        var outputPerMillion: Decimal
        var cacheWritePerMillion: Decimal
        var cacheReadPerMillion: Decimal
        var reasoningOutputPerMillion: Decimal
        var source: String
    }

    static func estimateCost(provider: String?, model: String?, tokens: UsageTokenBreakdown) -> UsageCostEstimate? {
        guard let rates = rates(provider: provider, model: model) else { return nil }
        guard tokens.input != nil
            || tokens.output != nil
            || tokens.cacheWrite != nil
            || tokens.cacheRead != nil
            || tokens.reasoningOutput != nil else {
            return nil
        }
        let cost = cost(for: tokens.input, rate: rates.inputPerMillion)
            + cost(for: tokens.output, rate: rates.outputPerMillion)
            + cost(for: tokens.cacheWrite, rate: rates.cacheWritePerMillion)
            + cost(for: tokens.cacheRead, rate: rates.cacheReadPerMillion)
            + cost(for: tokens.reasoningOutput, rate: rates.reasoningOutputPerMillion)
        return UsageCostEstimate(costUSD: cost, pricingSource: rates.source)
    }

    private static func rates(provider: String?, model: String?) -> Rates? {
        let provider = provider?.lowercased() ?? ""
        let model = model?.lowercased() ?? ""

        if provider.contains("anthropic") || model.contains("claude") {
            if model.contains("opus") {
                return Rates(
                    inputPerMillion: decimal("5"),
                    outputPerMillion: decimal("25"),
                    cacheWritePerMillion: decimal("6.25"),
                    cacheReadPerMillion: decimal("0.50"),
                    reasoningOutputPerMillion: decimal("25"),
                    source: "Anthropic API-equivalent local catalog"
                )
            }
            if model.contains("sonnet") {
                return Rates(
                    inputPerMillion: decimal("3"),
                    outputPerMillion: decimal("15"),
                    cacheWritePerMillion: decimal("3.75"),
                    cacheReadPerMillion: decimal("0.30"),
                    reasoningOutputPerMillion: decimal("15"),
                    source: "Anthropic API-equivalent local catalog"
                )
            }
            if model.contains("haiku") {
                return Rates(
                    inputPerMillion: decimal("0.80"),
                    outputPerMillion: decimal("4"),
                    cacheWritePerMillion: decimal("1"),
                    cacheReadPerMillion: decimal("0.08"),
                    reasoningOutputPerMillion: decimal("4"),
                    source: "Anthropic API-equivalent local catalog"
                )
            }
        }

        return nil
    }

    private static func cost(for tokens: Int?, rate: Decimal) -> Decimal {
        guard let tokens else { return 0 }
        return Decimal(tokens) * rate / Decimal(1_000_000)
    }

    private static func decimal(_ value: String) -> Decimal {
        NSDecimalNumber(string: value).decimalValue
    }
}

enum HarnessUsageFileHelpers {
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

    static func projectName(for cwd: String) -> String {
        let expanded = expandHome(cwd)
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        return name.isEmpty ? expanded : name
    }

    static func abbreviateHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func expandHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }
}

enum HarnessUsageJSON {
    static func object(fromLine line: Substring) -> [String: Any]? {
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

    static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let value as Decimal:
            return value
        case let value as NSNumber:
            return value.decimalValue
        case let value as Double:
            return Decimal(value)
        case let value as String:
            return Decimal(string: value)
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
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

    static func tokens(from usage: [String: Any]) -> UsageTokenBreakdown {
        UsageTokenBreakdown(
            input: int(usage["input"]) ?? int(usage["input_tokens"]),
            output: int(usage["output"]) ?? int(usage["output_tokens"]),
            cacheWrite: int(usage["cacheWrite"]) ?? int(usage["cache_creation_input_tokens"]),
            cacheRead: int(usage["cacheRead"]) ?? int(usage["cached_input_tokens"]) ?? int(usage["cache_read_input_tokens"]),
            reasoningOutput: int(usage["reasoning_output_tokens"]),
            total: int(usage["totalTokens"]) ?? int(usage["total_tokens"])
        )
    }
}
