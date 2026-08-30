//
//  CodexTokenStatsViewModel.swift
//  boringNotch
//

import Combine
import Foundation

struct DailyTokenUsage: Codable, Identifiable, Equatable, Sendable {
    let day: Date
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64

    var id: Date { day }
}

@MainActor
final class CodexTokenStatsViewModel: ObservableObject {
    static let shared = CodexTokenStatsViewModel()

    @Published private(set) var days: [DailyTokenUsage] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCompletedInitialScan = false

    private var sessionCache: [String: CachedSessionUsage] = [:]

    private init() {
        sessionCache = Self.loadPersistedCache()
        days = Self.makeDailyUsageFromCache(sessionCache)
    }

    var today: DailyTokenUsage? {
        let start = Calendar.current.startOfDay(for: Date())
        return days.first { Calendar.current.isDate($0.day, inSameDayAs: start) }
    }

    var todaySummary: String {
        Self.compactCount(today?.totalTokens ?? 0)
    }

    var totalObservedTokens: Int64 {
        days.reduce(0) { partial, day in
            let (sum, overflow) = partial.addingReportingOverflow(day.totalTokens)
            return overflow ? Int64.max : sum
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        do {
            let previousCache = sessionCache
            let result = try await Task.detached(priority: .utility) {
                try Self.scanLocalSessions(previousCache: previousCache)
            }.value
            days = result.days
            sessionCache = result.cache
            try? Self.persistCache(result.cache)
            lastUpdated = Date()
            hasCompletedInitialScan = true
            errorMessage = nil
            ResourceStatsViewModel.shared.tokenStatsDidRefresh()
        } catch {
            errorMessage = "Token 统计失败：\(error.localizedDescription)"
        }
    }

    static func compactCount(_ value: Int64) -> String {
        let yi = Double(value) / 100_000_000
        if value == 0 { return "0 亿" }
        return String(format: abs(yi) >= 1 ? "%.2f 亿" : "%.3f 亿", yi)
    }

    nonisolated private static func scanLocalSessions(
        previousCache: [String: CachedSessionUsage]
    ) throws -> TokenScanResult {
        let fileManager = FileManager.default
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let roots = [
            codexRoot.appendingPathComponent("sessions", isDirectory: true),
            codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        var selectedFiles: [String: URL] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                let key = fileURL.lastPathComponent
                guard let current = selectedFiles[key] else {
                    selectedFiles[key] = fileURL
                    continue
                }
                let currentDate = (try? current.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let candidateDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if candidateDate > currentDate {
                    selectedFiles[key] = fileURL
                }
            }
        }

        var totals: [Date: TokenVector] = [:]
        var nextCache: [String: CachedSessionUsage] = [:]
        for fileURL in selectedFiles.values {
            let values = try fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let key = fileURL.lastPathComponent
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0

            let cached: CachedSessionUsage
            if let previous = previousCache[key],
               previous.fileSize == size
            {
                cached = CachedSessionUsage(
                    path: fileURL.path,
                    fileSize: size,
                    modifiedAt: modified,
                    days: previous.days,
                    lastVector: previous.lastVector
                )
            } else if let previous = previousCache[key],
                      size > previous.fileSize,
                      let appended = try? readData(from: fileURL, offset: UInt64(previous.fileSize))
            {
                let parsed = parseSessionData(appended, previous: previous.lastVector)
                var merged: [Date: TokenVector] = [:]
                merge(previous.days, into: &merged)
                merge(parsed.days, into: &merged)
                cached = CachedSessionUsage(
                    path: fileURL.path,
                    fileSize: size,
                    modifiedAt: modified,
                    days: makeDailyUsage(from: merged),
                    lastVector: parsed.lastVector ?? previous.lastVector
                )
            } else {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let parsed = parseSessionData(data, previous: nil)
                cached = CachedSessionUsage(
                    path: fileURL.path,
                    fileSize: size,
                    modifiedAt: modified,
                    days: parsed.days,
                    lastVector: parsed.lastVector
                )
            }
            nextCache[key] = cached
            merge(cached.days, into: &totals)
        }

        return TokenScanResult(days: makeDailyUsage(from: totals), cache: nextCache)
    }

    nonisolated static func dailyUsage(fromSessionData data: Data) -> [DailyTokenUsage] {
        parseSessionData(data, previous: nil).days
    }

    nonisolated private static func makeDailyUsage(
        from totals: [Date: TokenVector]
    ) -> [DailyTokenUsage] {
        totals.map { day, value in
            DailyTokenUsage(
                day: day,
                inputTokens: value.input,
                cachedInputTokens: value.cached,
                outputTokens: value.output,
                reasoningTokens: value.reasoning,
                totalTokens: value.total
            )
        }
        .sorted { $0.day > $1.day }
    }

    nonisolated private static func merge(
        _ days: [DailyTokenUsage],
        into totals: inout [Date: TokenVector]
    ) {
        for day in days {
            totals[day.day, default: .zero].add(
                TokenVector(
                    input: day.inputTokens,
                    cached: day.cachedInputTokens,
                    output: day.outputTokens,
                    reasoning: day.reasoningTokens,
                    total: day.totalTokens
                )
            )
        }
    }

    nonisolated private static func parseSessionData(
        _ data: Data,
        previous initialPrevious: TokenVector?
    ) -> (days: [DailyTokenUsage], lastVector: TokenVector?) {
        var totals: [Date: TokenVector] = [:]
        var previous = initialPrevious
        let calendar = Calendar.current
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()

        data.split(separator: 0x0A).forEach { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let current = TokenVector(dictionary: usage),
                  let timestamp = object["timestamp"] as? String,
                  let date = fractionalFormatter.date(from: timestamp) ?? formatter.date(from: timestamp)
            else { return }

            let delta: TokenVector
            if let previous, current.total >= previous.total {
                guard current != previous else { return }
                delta = current.subtracting(previous)
            } else {
                delta = current
            }

            previous = current
            let day = calendar.startOfDay(for: date)
            totals[day, default: .zero].add(delta)
        }
        return (makeDailyUsage(from: totals), previous)
    }

    nonisolated private static func readData(from url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    nonisolated private static func makeDailyUsageFromCache(
        _ cache: [String: CachedSessionUsage]
    ) -> [DailyTokenUsage] {
        var totals: [Date: TokenVector] = [:]
        for entry in cache.values {
            merge(entry.days, into: &totals)
        }
        return makeDailyUsage(from: totals)
    }

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("codex-token-index-v2.json")
    }

    nonisolated private static func loadPersistedCache() -> [String: CachedSessionUsage] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode([String: CachedSessionUsage].self, from: data)
        else { return [:] }
        return cache
    }

    nonisolated private static func persistCache(
        _ cache: [String: CachedSessionUsage]
    ) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(cache)
        try data.write(to: cacheURL, options: .atomic)
    }
}

private struct TokenVector: Codable, Equatable, Sendable {
    var input: Int64
    var cached: Int64
    var output: Int64
    var reasoning: Int64
    var total: Int64

    static let zero = TokenVector(input: 0, cached: 0, output: 0, reasoning: 0, total: 0)

    init?(dictionary: [String: Any]) {
        guard let total = Self.integer(dictionary["total_tokens"]) else { return nil }
        input = Self.integer(dictionary["input_tokens"]) ?? 0
        cached = Self.integer(dictionary["cached_input_tokens"]) ?? 0
        output = Self.integer(dictionary["output_tokens"]) ?? 0
        reasoning = Self.integer(dictionary["reasoning_output_tokens"]) ?? 0
        self.total = total
    }

    init(input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }

    mutating func add(_ other: TokenVector) {
        input += other.input
        cached += other.cached
        output += other.output
        reasoning += other.reasoning
        total += other.total
    }

    func subtracting(_ other: TokenVector) -> TokenVector {
        TokenVector(
            input: max(0, input - other.input),
            cached: max(0, cached - other.cached),
            output: max(0, output - other.output),
            reasoning: max(0, reasoning - other.reasoning),
            total: max(0, total - other.total)
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

private struct CachedSessionUsage: Codable, Sendable {
    let path: String
    let fileSize: Int
    let modifiedAt: TimeInterval
    let days: [DailyTokenUsage]
    let lastVector: TokenVector?
}

private struct TokenScanResult: Sendable {
    let days: [DailyTokenUsage]
    let cache: [String: CachedSessionUsage]
}
