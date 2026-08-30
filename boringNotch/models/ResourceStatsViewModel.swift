//
//  ResourceStatsViewModel.swift
//  boringNotch
//

import Combine
import Darwin.Mach
import Foundation
import UserNotifications

struct CodexQuotaWindow: Equatable {
    let id: String
    let sourceID: String
    let label: String
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

enum CodexPlanTier: Equatable {
    case plus
    case pro
    case unknown(String?)

    init(planType: String?) {
        switch planType?.lowercased() {
        case "plus":
            self = .plus
        case "pro", "prolite":
            self = .pro
        default:
            self = .unknown(planType)
        }
    }

    var displayName: String {
        switch self {
        case .plus: return "PLUS"
        case .pro: return "PRO"
        case .unknown(let planType): return planType?.uppercased() ?? "UNKNOWN"
        }
    }
}

struct CodexQuotaSnapshot: Equatable {
    let session: CodexQuotaWindow?
    let weekly: CodexQuotaWindow?
    let allWindows: [CodexQuotaWindow]
    let planTier: CodexPlanTier

    var displayedWindow: CodexQuotaWindow? {
        switch planTier {
        case .plus: return session
        case .pro: return weekly
        case .unknown: return allWindows.max { $0.durationMinutes < $1.durationMinutes }
        }
    }

    var windowLabel: String? {
        switch planTier {
        case .plus: return "5小时"
        case .pro: return "周"
        case .unknown: return displayedWindow?.label
        }
    }
}

struct CodexQuotaSample: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let remainingPercent: Double
    let resetsAt: Date?
    let plan: String
    let windowMinutes: Int

    var id: Date { timestamp }
}

struct CodexQuotaForecast: Equatable, Sendable {
    let burnRatePerHour: Double
    let estimatedExhaustion: Date?
    let resetsAt: Date?

    var willExhaustBeforeReset: Bool {
        guard let estimatedExhaustion, let resetsAt else { return estimatedExhaustion != nil }
        return estimatedExhaustion < resetsAt
    }
}

enum CodexQuotaEstimateConfidence: String, Equatable, Sendable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

struct CodexQuotaTokenEstimate: Equatable, Sendable {
    let remainingTokens: Int64
    let lowerBoundTokens: Int64
    let upperBoundTokens: Int64
    let confidence: CodexQuotaEstimateConfidence
    let sampleCount: Int
}

struct CodexDailyBudget: Equatable, Sendable {
    let dayStart: Date
    let resetsAt: Date
    let budgetTokens: Int64
    let usedTokens: Int64

    var remainingTokens: Int64 {
        max(0, budgetTokens - usedTokens)
    }

    var usageRatio: Double {
        guard budgetTokens > 0 else { return 0 }
        return Double(usedTokens) / Double(budgetTokens)
    }
}

struct TiboResetSignal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case monitoring
        case possible
        case announced
        case synchronized
        case unavailable
    }

    let kind: Kind
    let title: String
    let detail: String
    let publishedAt: Date?
    let sourceURL: URL?
}

private struct CodexQuotaTokenCalibration: Codable, Sendable {
    var plan: String
    var resetsAt: Date?
    var lastRemainingPercent: Double
    var lastObservedTokens: Int64
    var tokensPerPercent: Double?
    var sampleCount: Int
    var observedRates: [Double]?
}

private struct CodexDailyBudgetNotificationState: Codable, Sendable {
    var dayStart: Date
    var resetsAt: Date
    var notifiedAt100Percent: Bool
    var notifiedAt150Percent: Bool
}

private struct CodexDailyBudgetSnapshot: Codable, Sendable {
    let dayStart: Date
    let resetsAt: Date
    let budgetTokens: Int64
    let createdAt: Date
}

@MainActor
final class ResourceStatsViewModel: ObservableObject {
    static let shared = ResourceStatsViewModel()
    private static let codexRefreshInterval: TimeInterval = 10 * 60
    private static let codexStaleInterval: TimeInterval = 20 * 60
    private static let quotaHistoryKey = "codexQuotaHistoryV1"
    private static let quotaTokenCalibrationKey = "codexQuotaTokenCalibrationV1"
    private static let unattributedTokensKey = "codexUnattributedDailyTokensV1"
    private static let dailyBudgetNotificationKey = "codexDailyBudgetNotificationV1"
    private static let dailyBudgetSnapshotKey = "codexDailyBudgetSnapshotV2"
    private static let lastTiboHardResetEventIDKey = "lastTiboHardResetEventIDV1"
    private static let tiboWaitingForSyncKey = "tiboWaitingForQuotaSyncV1"
    private static let tiboBaselineRemainingKey = "tiboResetBaselineRemainingV1"
    private static let tiboBaselineResetDateKey = "tiboResetBaselineResetDateV1"
    private static let tiboRefreshInterval: TimeInterval = 60 * 60
    private static let tiboEventsURL = URL(
        string: "https://tibo.modelyard.dev/api/events?limit=20"
    )!

    @Published private(set) var codexQuota: CodexQuotaSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var isRefreshingCodex = false
    @Published private(set) var lastCodexAttempt: Date?
    @Published private(set) var lastCodexUpdate: Date?
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var compressedMemoryBytes: UInt64 = 0
    @Published private(set) var swapUsedBytes: UInt64 = 0
    @Published private(set) var swapTotalBytes: UInt64 = 0
    @Published private(set) var memoryPressure = "正常"
    @Published private(set) var quotaHistory: [CodexQuotaSample] = []
    @Published private(set) var quotaTokenEstimate: CodexQuotaTokenEstimate?
    @Published private(set) var unattributedDailyTokens: [String: Int64] = [:]
    @Published private(set) var dailyBudget: CodexDailyBudget?
    @Published private(set) var tiboResetSignal = TiboResetSignal(
        kind: .monitoring,
        title: "正在监控 Tibo 硬重置",
        detail: "每小时检查一次",
        publishedAt: nil,
        sourceURL: nil
    )
    @Published private(set) var lastTiboCheck: Date?
    @Published private(set) var lastTiboSuccess: Date?
    @Published private(set) var tiboError: String?
    @Published private(set) var isRefreshingTibo = false

    private var memoryTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?
    private var tiboTask: Task<Void, Never>?
    private var quotaTokenCalibration: CodexQuotaTokenCalibration?
    private var dailyBudgetNotificationState: CodexDailyBudgetNotificationState?
    private var dailyBudgetSnapshot: CodexDailyBudgetSnapshot?
    private var tiboWaitingForQuotaSync: Bool
    private var codexFailureCount = 0
    private var tiboFailureCount = 0

    private init() {
        tiboWaitingForQuotaSync = UserDefaults.standard.bool(
            forKey: Self.tiboWaitingForSyncKey
        )
        if let data = UserDefaults.standard.data(forKey: Self.quotaHistoryKey),
           let decoded = try? JSONDecoder().decode([CodexQuotaSample].self, from: data)
        {
            quotaHistory = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.quotaTokenCalibrationKey),
           let decoded = try? JSONDecoder().decode(CodexQuotaTokenCalibration.self, from: data)
        {
            quotaTokenCalibration = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.unattributedTokensKey),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data)
        {
            unattributedDailyTokens = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.dailyBudgetNotificationKey),
           let decoded = try? JSONDecoder().decode(
               CodexDailyBudgetNotificationState.self,
               from: data
           )
        {
            dailyBudgetNotificationState = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.dailyBudgetSnapshotKey),
           let decoded = try? JSONDecoder().decode(CodexDailyBudgetSnapshot.self, from: data)
        {
            dailyBudgetSnapshot = decoded
        }
    }

    var memoryUsedFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(1, max(0, Double(memoryUsedBytes) / Double(memoryTotalBytes)))
    }

    var memoryUsedPercent: Double {
        memoryUsedFraction * 100
    }

    var codexSummary: String {
        guard let quota = codexQuota,
              let label = quota.windowLabel,
              let remaining = quota.displayedWindow?.remainingPercent
        else { return "--" }
        return "\(label) \(Int(remaining.rounded()))%"
    }

    var codexRemainingPercentSummary: String {
        guard let remaining = codexQuota?.displayedWindow?.remainingPercent else { return "--" }
        return "\(Int(remaining.rounded()))%"
    }

    var memorySummary: String {
        "\(Int(memoryUsedPercent.rounded()))%"
    }

    var formattedMemoryUsage: String {
        "\(Self.formatBytes(memoryUsedBytes)) / \(Self.formatBytes(memoryTotalBytes))"
    }

    var isCodexStale: Bool {
        guard codexQuota != nil else { return false }
        if codexError != nil { return true }
        guard let lastCodexUpdate else { return true }
        return Date().timeIntervalSince(lastCodexUpdate) >= Self.codexStaleInterval
    }

    var isTiboStale: Bool {
        guard let lastTiboSuccess else { return true }
        return tiboError != nil || Date().timeIntervalSince(lastTiboSuccess) >= 2 * 60 * 60
    }

    var quotaForecast: CodexQuotaForecast? {
        Self.makeForecast(from: quotaHistory)
    }

    var quotaForecastSummary: String {
        guard let forecast = quotaForecast else { return "样本不足，正在学习使用速度" }
        let rate = String(format: "%.1f%%/小时", forecast.burnRatePerHour)
        guard let exhaustion = forecast.estimatedExhaustion else {
            return "当前消耗速度很低 · \(rate)"
        }
        if forecast.willExhaustBeforeReset {
            return "预计耗尽于 \(Self.shortTime(exhaustion)) · \(rate)"
        }
        return "按当前速度不会在重置前耗尽 · \(rate)"
    }

    var estimatedQuotaRemainingSummary: String {
        guard let estimate = quotaTokenEstimate else {
            return "正在学习（需观察额度变化）"
        }
        return "约 \(CodexTokenStatsViewModel.compactCount(estimate.remainingTokens))（本地估算）"
    }

    var compactEstimatedQuotaRemainingSummary: String {
        guard let estimate = quotaTokenEstimate else { return "估算学习中" }
        return "余约 \(CodexTokenStatsViewModel.compactCount(estimate.remainingTokens))"
    }

    var quotaEstimateRangeSummary: String {
        guard let estimate = quotaTokenEstimate else { return "暂不可用" }
        return "\(CodexTokenStatsViewModel.compactCount(estimate.lowerBoundTokens))–\(CodexTokenStatsViewModel.compactCount(estimate.upperBoundTokens))"
    }

    var quotaEstimateConfidenceSummary: String {
        guard let estimate = quotaTokenEstimate else { return "学习中 · 0 个样本" }
        return "\(estimate.confidence.title)置信度 · \(estimate.sampleCount) 个样本"
    }

    var unattributedTodayTokens: Int64 {
        unattributedDailyTokens[Self.dayKey(Date())] ?? 0
    }

    var unattributedTodaySummary: String {
        guard unattributedTodayTokens > 0 else { return "未检测到" }
        return "约 \(CodexTokenStatsViewModel.compactCount(unattributedTodayTokens)) · \(unattributedConfidenceTitle)置信度"
    }

    private var unattributedConfidenceTitle: String {
        guard let estimate = quotaTokenEstimate else { return "低" }
        switch estimate.confidence {
        case .high: return "中"
        case .medium, .low: return "低"
        }
    }

    var dailyBudgetCompactSummary: String {
        guard let budget = dailyBudget else { return "今日预算学习中" }
        return "今 \(Self.compactTokenCount(budget.usedTokens))/\(Self.compactTokenCount(budget.budgetTokens))亿"
    }

    var dailyBudgetProgressSummary: String {
        guard let budget = dailyBudget else { return "正在学习额度换算" }
        return "\(CodexTokenStatsViewModel.compactCount(budget.usedTokens)) / \(CodexTokenStatsViewModel.compactCount(budget.budgetTokens))"
    }

    var dailyBudgetRemainingSummary: String {
        guard let budget = dailyBudget else { return "暂不可用" }
        return CodexTokenStatsViewModel.compactCount(budget.remainingTokens)
    }

    var dailyBudgetPercentSummary: String {
        guard let budget = dailyBudget else { return "--" }
        return "\(Int((budget.usageRatio * 100).rounded()))%"
    }

    var quotaResetCountdownSummary: String {
        guard let resetsAt = codexQuota?.displayedWindow?.resetsAt else { return "未知" }
        return Self.durationSummary(until: resetsAt)
    }

    var currentQuotaHistory: [CodexQuotaSample] {
        guard let latest = quotaHistory.last else { return [] }
        return quotaHistory.filter {
            $0.plan == latest.plan && Self.sameReset($0.resetsAt, latest.resetsAt)
        }
    }

    func startRefreshing() {
        if memoryTask == nil {
            updateMemoryUsage()
            memoryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { break }
                    self?.updateMemoryUsage()
                }
            }
        }

        if codexTask == nil {
            codexTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshCodexQuota()
                    let interval = self?.codexNextRefreshInterval ?? Self.codexRefreshInterval
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }

        if tiboTask == nil {
            tiboTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshTiboStatus()
                    let interval = self?.tiboNextRefreshInterval ?? Self.tiboRefreshInterval
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
    }

    func refreshCodexIfNeeded(maxAge: TimeInterval = 60) {
        let shouldRefresh = codexError != nil
            || lastCodexUpdate == nil
            || Date().timeIntervalSince(lastCodexUpdate ?? .distantPast) >= maxAge
        guard shouldRefresh else { return }
        Task { [weak self] in
            await self?.refreshCodexQuota()
        }
    }

    func refreshNow() {
        updateMemoryUsage()
        Task { [weak self] in
            await self?.refreshCodexQuota()
            await self?.refreshTiboStatus()
        }
    }

    func refreshAfterWake() {
        Task { [weak self] in
            await self?.refreshCodexQuota()
            await self?.refreshTiboStatus()
        }
    }

    func tokenStatsDidRefresh() {
        recalculateDailyBudgetAndNotify()
    }

    func refreshCodexQuota() async {
        guard !isRefreshingCodex else { return }
        isRefreshingCodex = true
        lastCodexAttempt = Date()
        defer { isRefreshingCodex = false }

        do {
            await CodexTokenStatsViewModel.shared.refresh()
            let responseText = try await XPCHelperClient.shared.readCodexRateLimits()
            let data = Data(responseText.utf8)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(CodexProbePayload.self, from: data)
            if let error = payload.account.error {
                throw CodexQuotaError.server(error.message)
            }
            if let error = payload.rateLimits.error {
                throw CodexQuotaError.server(error.message)
            }
            guard let result = payload.rateLimits.result else {
                throw CodexQuotaError.missingResult
            }

            let selectedQuota = try CodexQuotaSelector.select(
                from: result,
                accountPlanType: payload.account.result?.account?.planType
            )
            let previousQuota = codexQuota
            codexQuota = selectedQuota
            codexError = nil
            codexFailureCount = 0
            lastCodexUpdate = Date()
            recordQuotaSample(selectedQuota)
            updateQuotaTokenEstimate(selectedQuota)
            detectTiboQuotaSynchronization(from: previousQuota, to: selectedQuota)
            recalculateDailyBudgetAndNotify()
        } catch {
            codexError = error.localizedDescription
            codexFailureCount += 1
        }
    }

    func refreshTiboStatus() async {
        guard !isRefreshingTibo else { return }
        isRefreshingTibo = true
        defer { isRefreshingTibo = false }

        do {
            var request = URLRequest(url: Self.tiboEventsURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 15
            request.setValue("boringNotch/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw TiboMonitorError.invalidResponse
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(TiboEventsEnvelope.self, from: data)
            lastTiboCheck = Date()
            lastTiboSuccess = Date()
            tiboError = nil
            tiboFailureCount = 0

            let hardReset = envelope.data.first(where: Self.isVerifiedHardReset)
            let possibleReset = envelope.data.first { event in
                event.category == "RESET_PLANNED" && !Self.isBankedReset(event)
            }

            if let hardReset {
                handleTiboHardResetEvent(hardReset)
            }

            if tiboWaitingForQuotaSync, let hardReset {
                tiboResetSignal = Self.signal(
                    for: hardReset,
                    kind: .announced,
                    detail: "硬重置已宣布，等待账户同步"
                )
            } else if let possibleReset,
                      possibleReset.publishedDate ?? .distantPast
                          > (hardReset?.publishedDate ?? .distantPast)
            {
                tiboResetSignal = Self.signal(
                    for: possibleReset,
                    kind: .possible,
                    detail: "可能发生硬重置，仅在面板显示"
                )
            } else if tiboResetSignal.kind != .synchronized {
                tiboResetSignal = TiboResetSignal(
                    kind: .monitoring,
                    title: "未发现新的 Tibo 硬重置",
                    detail: "每小时检查一次",
                    publishedAt: hardReset?.publishedDate,
                    sourceURL: hardReset?.sourceLink
                )
            }
        } catch {
            lastTiboCheck = Date()
            tiboError = error.localizedDescription
            tiboFailureCount += 1
        }
    }

    private var codexNextRefreshInterval: TimeInterval {
        switch codexFailureCount {
        case 1: 60
        case 2: 2 * 60
        default: Self.codexRefreshInterval
        }
    }

    private var tiboNextRefreshInterval: TimeInterval {
        switch tiboFailureCount {
        case 1: 5 * 60
        case 2: 15 * 60
        default: Self.tiboRefreshInterval
        }
    }

    private func handleTiboHardResetEvent(_ event: TiboResetEventPayload) {
        let defaults = UserDefaults.standard
        let storedID = defaults.object(forKey: Self.lastTiboHardResetEventIDKey) as? Int
        guard storedID != event.id else { return }

        defaults.set(event.id, forKey: Self.lastTiboHardResetEventIDKey)
        let isRecent = event.publishedDate.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age <= Self.tiboRefreshInterval
        } ?? false

        // The first successful fetch establishes a baseline. It only alerts if
        // the announcement is recent enough to have occurred within one poll.
        guard storedID != nil || isRecent else { return }

        tiboWaitingForQuotaSync = true
        defaults.set(true, forKey: Self.tiboWaitingForSyncKey)
        if let window = codexQuota?.displayedWindow {
            defaults.set(window.remainingPercent, forKey: Self.tiboBaselineRemainingKey)
            defaults.set(
                window.resetsAt?.timeIntervalSinceReferenceDate,
                forKey: Self.tiboBaselineResetDateKey
            )
        }

        sendNotification(
            identifier: "tibo-hard-reset-\(event.id)",
            title: "Tibo 硬重置已宣布",
            body: event.titleZh ?? event.titleEn ?? "等待账户额度同步",
            destination: "quotaBudget"
        )
    }

    private func detectTiboQuotaSynchronization(
        from previous: CodexQuotaSnapshot?,
        to current: CodexQuotaSnapshot
    ) {
        guard tiboWaitingForQuotaSync,
              let currentWindow = current.displayedWindow
        else { return }

        let defaults = UserDefaults.standard
        let baselineRemaining = previous?.displayedWindow?.remainingPercent
            ?? (defaults.object(forKey: Self.tiboBaselineRemainingKey) as? Double)
        let baselineResetDate = previous?.displayedWindow?.resetsAt
            ?? (defaults.object(forKey: Self.tiboBaselineResetDateKey) as? Double)
                .map(Date.init(timeIntervalSinceReferenceDate:))

        let quotaRecovered = baselineRemaining.map {
            currentWindow.remainingPercent - $0 >= 20
        } ?? false
        let resetDateChanged: Bool
        if let baselineResetDate {
            resetDateChanged = !Self.sameReset(baselineResetDate, currentWindow.resetsAt)
                && currentWindow.remainingPercent >= (baselineRemaining ?? 0)
        } else {
            resetDateChanged = false
        }

        guard quotaRecovered || resetDateChanged else { return }
        tiboWaitingForQuotaSync = false
        defaults.set(false, forKey: Self.tiboWaitingForSyncKey)
        defaults.removeObject(forKey: Self.tiboBaselineRemainingKey)
        defaults.removeObject(forKey: Self.tiboBaselineResetDateKey)
        dailyBudgetSnapshot = nil
        defaults.removeObject(forKey: Self.dailyBudgetSnapshotKey)
        dailyBudgetNotificationState = nil
        defaults.removeObject(forKey: Self.dailyBudgetNotificationKey)
        tiboResetSignal = TiboResetSignal(
            kind: .synchronized,
            title: "Tibo 硬重置已同步",
            detail: "额度与每日预算已重新计算",
            publishedAt: Date(),
            sourceURL: tiboResetSignal.sourceURL
        )
    }

    private func recalculateDailyBudgetAndNotify() {
        guard let resetsAt = codexQuota?.displayedWindow?.resetsAt
        else {
            dailyBudget = nil
            return
        }

        let now = Date()
        guard resetsAt > now else {
            dailyBudget = nil
            return
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let localUsedTokens = CodexTokenStatsViewModel.shared.today?.totalTokens ?? 0
        let (combinedUsed, combinedOverflow) = localUsedTokens.addingReportingOverflow(
            unattributedTodayTokens
        )
        let usedTokens = combinedOverflow ? Int64.max : combinedUsed
        let snapshot: CodexDailyBudgetSnapshot
        if let current = dailyBudgetSnapshot,
           calendar.isDate(current.dayStart, inSameDayAs: dayStart),
           Self.sameReset(current.resetsAt, resetsAt)
        {
            snapshot = current
        } else {
            guard CodexTokenStatsViewModel.shared.hasCompletedInitialScan,
                  let estimate = quotaTokenEstimate
            else {
                dailyBudget = nil
                return
            }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? resetsAt
            let allocationEnd = min(nextDay, resetsAt)
            let cycleSeconds = max(1, resetsAt.timeIntervalSince(dayStart))
            let todaySeconds = max(0, allocationEnd.timeIntervalSince(dayStart))
            let fraction = min(1, max(0, todaySeconds / cycleSeconds))
            let (pool, overflow) = estimate.remainingTokens.addingReportingOverflow(usedTokens)
            let availableAtDayStart = overflow ? Int64.max : pool
            let budgetTokens = Int64(
                min(Double(Int64.max), Double(availableAtDayStart) * fraction).rounded()
            )
            snapshot = CodexDailyBudgetSnapshot(
                dayStart: dayStart,
                resetsAt: resetsAt,
                budgetTokens: budgetTokens,
                createdAt: now
            )
            dailyBudgetSnapshot = snapshot
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.dailyBudgetSnapshotKey)
            }
        }

        let budget = CodexDailyBudget(
            dayStart: dayStart,
            resetsAt: resetsAt,
            budgetTokens: snapshot.budgetTokens,
            usedTokens: usedTokens
        )
        dailyBudget = budget
        evaluateBudgetNotifications(for: budget)
    }

    private func evaluateBudgetNotifications(for budget: CodexDailyBudget) {
        var state = dailyBudgetNotificationState
        if state == nil
            || !Calendar.current.isDate(state!.dayStart, inSameDayAs: budget.dayStart)
            || !Self.sameReset(state!.resetsAt, budget.resetsAt)
        {
            state = CodexDailyBudgetNotificationState(
                dayStart: budget.dayStart,
                resetsAt: budget.resetsAt,
                notifiedAt100Percent: false,
                notifiedAt150Percent: false
            )
        }

        guard var updatedState = state else { return }
        if budget.usageRatio >= 1.5, !updatedState.notifiedAt150Percent {
            updatedState.notifiedAt100Percent = true
            updatedState.notifiedAt150Percent = true
            sendBudgetNotification(threshold: 150, budget: budget)
        } else if budget.usageRatio >= 1, !updatedState.notifiedAt100Percent {
            updatedState.notifiedAt100Percent = true
            sendBudgetNotification(threshold: 100, budget: budget)
        }

        dailyBudgetNotificationState = updatedState
        if let data = try? JSONEncoder().encode(updatedState) {
            UserDefaults.standard.set(data, forKey: Self.dailyBudgetNotificationKey)
        }
    }

    private func sendBudgetNotification(threshold: Int, budget: CodexDailyBudget) {
        let dayID = Int(budget.dayStart.timeIntervalSince1970)
        sendNotification(
            identifier: "codex-daily-budget-\(dayID)-\(threshold)",
            title: "今日 Codex 预算达到 \(threshold)%",
            body: "已用 \(CodexTokenStatsViewModel.compactCount(budget.usedTokens))，今日预算 \(CodexTokenStatsViewModel.compactCount(budget.budgetTokens))。",
            destination: "quotaBudget"
        )
    }

    private func sendNotification(
        identifier: String,
        title: String,
        body: String,
        destination: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["destination": destination]
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func updateMemoryUsage() {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return }

        // Active + wired + compressed pages closely matches the memory pressure
        // users care about while excluding readily reclaimable file cache.
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let calculated = usedPages * UInt64(vm_kernel_page_size)
        memoryUsedBytes = min(calculated, memoryTotalBytes)
        compressedMemoryBytes = UInt64(statistics.compressor_page_count)
            * UInt64(vm_kernel_page_size)
        updateSwapAndPressure()
    }

    private func updateSwapAndPressure() {
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsedBytes = swap.xsu_used
            swapTotalBytes = swap.xsu_total
        }

        var pressureLevel: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &pressureLevel,
            &pressureSize,
            nil,
            0
        ) == 0 {
            memoryPressure = switch pressureLevel {
            case 4: "严重"
            case 2: "警告"
            default: "正常"
            }
        }
    }

    private func recordQuotaSample(_ snapshot: CodexQuotaSnapshot) {
        guard let window = snapshot.displayedWindow else { return }
        let now = Date()
        let sample = CodexQuotaSample(
            timestamp: now,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            plan: snapshot.planTier.displayName,
            windowMinutes: window.durationMinutes
        )

        if let last = quotaHistory.last,
           now.timeIntervalSince(last.timestamp) < 60,
           last.plan == sample.plan,
           Self.sameReset(last.resetsAt, sample.resetsAt)
        {
            quotaHistory[quotaHistory.count - 1] = sample
        } else {
            quotaHistory.append(sample)
        }

        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        quotaHistory = Array(quotaHistory.filter { $0.timestamp >= cutoff }.suffix(5_000))
        if let data = try? JSONEncoder().encode(quotaHistory) {
            UserDefaults.standard.set(data, forKey: Self.quotaHistoryKey)
        }
    }

    private func updateQuotaTokenEstimate(_ snapshot: CodexQuotaSnapshot) {
        guard let window = snapshot.displayedWindow else { return }
        let observedTokens = CodexTokenStatsViewModel.shared.totalObservedTokens
        guard observedTokens > 0 else {
            // Token log scanning can finish after the quota request on launch.
            // Keep showing the persisted estimate instead of temporarily
            // falling back to an empty learning state until the next refresh.
            quotaTokenEstimate = quotaTokenCalibration.flatMap {
                Self.makeTokenEstimate(from: $0, remainingPercent: window.remainingPercent)
            }
            return
        }

        let plan = snapshot.planTier.displayName
        var calibration = quotaTokenCalibration

        if calibration?.plan != plan {
            calibration = CodexQuotaTokenCalibration(
                plan: plan,
                resetsAt: window.resetsAt,
                lastRemainingPercent: window.remainingPercent,
                lastObservedTokens: observedTokens,
                tokensPerPercent: nil,
                sampleCount: 0,
                observedRates: []
            )
        } else if let current = calibration,
                  Self.sameReset(current.resetsAt, window.resetsAt)
        {
            let percentConsumed = current.lastRemainingPercent - window.remainingPercent
            let tokenDelta = observedTokens - current.lastObservedTokens

            if percentConsumed >= 0.05, tokenDelta >= 0 {
                var shouldCalibrate = true
                if let establishedRate = current.tokensPerPercent,
                   current.sampleCount >= 2
                {
                    let estimatedAccountDelta = Int64(
                        min(Double(Int64.max), establishedRate * percentConsumed).rounded()
                    )
                    let unattributed = max(0, estimatedAccountDelta - tokenDelta)
                    if unattributed > 0 {
                        recordUnattributedTokens(unattributed, at: Date())
                        shouldCalibrate = unattributed < max(1_000_000, estimatedAccountDelta / 10)
                    }
                }
                let observedRate = Double(tokenDelta) / percentConsumed
                if shouldCalibrate, tokenDelta > 0, observedRate.isFinite, observedRate > 0 {
                    var rates = current.observedRates
                        ?? current.tokensPerPercent.map { [$0] }
                        ?? []
                    rates.append(observedRate)
                    rates = Array(rates.suffix(12))
                    calibration?.observedRates = rates
                    calibration?.tokensPerPercent = Self.median(rates)
                    calibration?.sampleCount = rates.count
                }
                calibration?.lastRemainingPercent = window.remainingPercent
                calibration?.lastObservedTokens = observedTokens
            } else if percentConsumed < -0.05 || tokenDelta < 0 {
                calibration?.lastRemainingPercent = window.remainingPercent
                calibration?.lastObservedTokens = observedTokens
            }
        } else {
            // The plan is unchanged, so retain its robust conversion samples
            // across quota cycles and only reset the cycle baselines.
            calibration?.resetsAt = window.resetsAt
            calibration?.lastRemainingPercent = window.remainingPercent
            calibration?.lastObservedTokens = observedTokens
        }

        quotaTokenCalibration = calibration
        quotaTokenEstimate = calibration.flatMap {
            Self.makeTokenEstimate(from: $0, remainingPercent: window.remainingPercent)
        }

        if let calibration,
           let data = try? JSONEncoder().encode(calibration)
        {
            UserDefaults.standard.set(data, forKey: Self.quotaTokenCalibrationKey)
        }
    }

    private nonisolated static func makeTokenEstimate(
        from calibration: CodexQuotaTokenCalibration,
        remainingPercent: Double
    ) -> CodexQuotaTokenEstimate? {
        let rates = (calibration.observedRates
            ?? calibration.tokensPerPercent.map { [$0] }
            ?? [])
            .filter { $0.isFinite && $0 > 0 }
        guard !rates.isEmpty else { return nil }

        let centerRate = median(rates)
        let deviations = rates.map { abs($0 - centerRate) }
        let relativeSpread = centerRate > 0 ? median(deviations) / centerRate : 1
        let sampleCount = rates.count

        let confidence: CodexQuotaEstimateConfidence
        if sampleCount <= 2 {
            confidence = .low
        } else if sampleCount <= 5 {
            confidence = relativeSpread <= 0.50 ? .medium : .low
        } else if relativeSpread <= 0.25 {
            confidence = .high
        } else if relativeSpread <= 0.50 {
            confidence = .medium
        } else {
            confidence = .low
        }

        let baseMargin: Double
        switch sampleCount {
        case 1: baseMargin = 0.40
        case 2: baseMargin = 0.30
        case 3...5: baseMargin = 0.20
        default: baseMargin = 0.12
        }
        let robustMargin = min(0.75, relativeSpread * 1.4826 * 1.5)
        let margin = max(baseMargin, robustMargin)
        let center = max(0, centerRate * remainingPercent)

        return CodexQuotaTokenEstimate(
            remainingTokens: Int64(center.rounded()),
            lowerBoundTokens: Int64(max(0, center * (1 - margin)).rounded()),
            upperBoundTokens: Int64(max(0, center * (1 + margin)).rounded()),
            confidence: confidence,
            sampleCount: sampleCount
        )
    }

    private nonisolated static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func recordUnattributedTokens(_ tokens: Int64, at date: Date) {
        let key = Self.dayKey(date)
        let current = unattributedDailyTokens[key] ?? 0
        let (sum, overflow) = current.addingReportingOverflow(tokens)
        unattributedDailyTokens[key] = overflow ? Int64.max : sum

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: date) ?? .distantPast
        unattributedDailyTokens = unattributedDailyTokens.filter { key, _ in
            guard let interval = TimeInterval(key) else { return false }
            return Date(timeIntervalSinceReferenceDate: interval) >= cutoff
        }
        if let data = try? JSONEncoder().encode(unattributedDailyTokens) {
            UserDefaults.standard.set(data, forKey: Self.unattributedTokensKey)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        String(Int(Calendar.current.startOfDay(for: date).timeIntervalSinceReferenceDate))
    }

    nonisolated static func makeForecast(
        from samples: [CodexQuotaSample]
    ) -> CodexQuotaForecast? {
        guard let latest = samples.last else { return nil }
        let lookback: TimeInterval = latest.windowMinutes <= 6 * 60 ? 2 * 60 * 60 : 24 * 60 * 60
        let cutoff = latest.timestamp.addingTimeInterval(-lookback)
        let usable = samples.filter {
            $0.timestamp >= cutoff
                && $0.plan == latest.plan
                && sameReset($0.resetsAt, latest.resetsAt)
        }
        guard usable.count >= 2,
              let first = usable.first,
              latest.timestamp.timeIntervalSince(first.timestamp) >= 60
        else { return nil }

        let origin = first.timestamp.timeIntervalSinceReferenceDate
        let points = usable.map {
            (
                x: ($0.timestamp.timeIntervalSinceReferenceDate - origin) / 3_600,
                y: $0.remainingPercent
            )
        }
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + pow($1.x - meanX, 2) }
        guard denominator > 0 else { return nil }

        let burnRate = max(0, -(numerator / denominator))
        let exhaustion: Date?
        if burnRate >= 0.05, latest.remainingPercent > 0 {
            exhaustion = latest.timestamp.addingTimeInterval(
                latest.remainingPercent / burnRate * 3_600
            )
        } else {
            exhaustion = nil
        }
        return CodexQuotaForecast(
            burnRatePerHour: burnRate,
            estimatedExhaustion: exhaustion,
            resetsAt: latest.resetsAt
        )
    }

    nonisolated private static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case let (.some(lhs), .some(rhs)): return abs(lhs.timeIntervalSince(rhs)) < 2
        default: return false
        }
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func compactTokenCount(_ value: Int64) -> String {
        let yi = Double(value) / 100_000_000
        if value == 0 { return "0" }
        return String(format: abs(yi) >= 1 ? "%.2f" : "%.3f", yi)
    }

    private static func durationSummary(until date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 60 { return "即将重置" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "还剩 \(days)天\(hours)小时" }
        if hours > 0 { return "还剩 \(hours)小时\(minutes)分钟" }
        return "还剩 \(minutes)分钟"
    }

    private static func isVerifiedHardReset(_ event: TiboResetEventPayload) -> Bool {
        event.category == "RESET_COMPLETED"
            && event.confidence >= 0.8
            && event.sourceQuality == "DIRECT"
            && event.verificationStatus == "DIRECT_VERIFIED"
            && !isBankedReset(event)
    }

    private static func isBankedReset(_ event: TiboResetEventPayload) -> Bool {
        let text = [
            event.titleEn,
            event.titleZh,
            event.summaryEn,
            event.summaryZh,
            event.sourceText,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        return text.contains("banked reset")
            || text.contains("banked-reset")
            || text.contains("储备重置")
            || text.contains("储存重置")
            || text.contains("银行重置")
    }

    private static func signal(
        for event: TiboResetEventPayload,
        kind: TiboResetSignal.Kind,
        detail: String
    ) -> TiboResetSignal {
        TiboResetSignal(
            kind: kind,
            title: event.titleZh ?? event.titleEn ?? "Tibo 硬重置动态",
            detail: detail,
            publishedAt: event.publishedDate,
            sourceURL: event.sourceLink
        )
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

private struct TiboEventsEnvelope: Decodable {
    let data: [TiboResetEventPayload]
}

private struct TiboResetEventPayload: Decodable {
    let id: Int
    let category: String
    let titleEn: String?
    let titleZh: String?
    let summaryEn: String?
    let summaryZh: String?
    let confidence: Double
    let publishedAt: String?
    let sourceURL: String?
    let sourceText: String?
    let sourceQuality: String?
    let verificationStatus: String?

    var sourceLink: URL? {
        sourceURL.flatMap(URL.init(string:))
    }

    var publishedDate: Date? {
        guard let publishedAt else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: publishedAt) ?? ISO8601DateFormatter().date(from: publishedAt)
    }
}

private enum TiboMonitorError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Tibo 状态服务响应无效"
    }
}

private struct CodexProbePayload: Decodable {
    let account: CodexAccountEnvelope
    let rateLimits: CodexRateLimitsEnvelope
}

private struct CodexAccountEnvelope: Decodable {
    let result: CodexAccountResult?
    let error: CodexRPCError?
}

private struct CodexAccountResult: Decodable {
    let account: CodexAccount?
}

private struct CodexAccount: Decodable {
    let planType: String?
}

private struct CodexRateLimitsEnvelope: Decodable {
    let result: CodexRateLimitsResult?
    let error: CodexRPCError?
}

private struct CodexRPCError: Decodable {
    let code: Int?
    let message: String
}

private struct CodexRateLimitsResult: Decodable {
    let rateLimits: CodexRateLimitSnapshot?
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

private struct CodexRateLimitSnapshot: Decodable {
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMins
        case windowDurationSeconds
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.flexibleDouble(forKey: .usedPercent)

        if let minutes = container.flexibleInt(forKey: .windowDurationMins) {
            windowDurationMins = minutes
        } else if let seconds = container.flexibleInt(forKey: .windowDurationSeconds) {
            windowDurationMins = max(1, (seconds + 59) / 60)
        } else {
            windowDurationMins = nil
        }

        resetsAt = container.flexibleDate(forKey: .resetsAt)
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite {
            return Int(value.rounded())
        }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func flexibleDate(forKey key: Key) -> Date? {
        if let seconds = try? decode(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if let seconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = try? decode(String.self, forKey: key) {
            if let seconds = TimeInterval(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}

private enum CodexQuotaSelector {
    private struct Candidate {
        let id: String
        let role: String
        let window: CodexRateLimitWindow
        let planType: String?
    }

    static func select(
        from result: CodexRateLimitsResult,
        accountPlanType: String?
    ) throws -> CodexQuotaSnapshot {
        var candidates: [Candidate] = []

        let namedLimits = result.rateLimitsByLimitId ?? [:]
        if namedLimits.isEmpty {
            if let snapshot = result.rateLimits {
                append(snapshot, id: "default", to: &candidates)
            }
        } else {
            for (id, snapshot) in namedLimits.sorted(by: { $0.key < $1.key }) {
                append(snapshot, id: id, to: &candidates)
            }
        }

        let usable = candidates.filter {
            $0.window.usedPercent != nil && $0.window.windowDurationMins != nil
        }
        guard !usable.isEmpty else { throw CodexQuotaError.noWindows }

        let sessionCandidate = nearest(
            to: 5 * 60,
            in: usable.filter { (4 * 60...6 * 60).contains($0.window.windowDurationMins ?? 0) }
        )
        let weeklyCandidate = nearest(
            to: 7 * 24 * 60,
            in: usable.filter { (6 * 24 * 60...8 * 24 * 60).contains($0.window.windowDurationMins ?? 0) }
        ) ?? usable.max { lhs, rhs in
            (lhs.window.windowDurationMins ?? 0) < (rhs.window.windowDurationMins ?? 0)
        }

        guard sessionCandidate != nil || weeklyCandidate != nil else {
            throw CodexQuotaError.noWindows
        }

        let allWindows = usable
            .map(makeWindow)
            .sorted { $0.durationMinutes < $1.durationMinutes }

        return CodexQuotaSnapshot(
            session: sessionCandidate.map(makeWindow),
            weekly: weeklyCandidate.map(makeWindow),
            allWindows: allWindows,
            planTier: CodexPlanTier(
                planType: accountPlanType
                    ?? weeklyCandidate?.planType
                    ?? sessionCandidate?.planType
            )
        )
    }

    private static func append(
        _ snapshot: CodexRateLimitSnapshot,
        id: String,
        to candidates: inout [Candidate]
    ) {
        if let primary = snapshot.primary {
            candidates.append(Candidate(id: id, role: "primary", window: primary, planType: snapshot.planType))
        }
        if let secondary = snapshot.secondary {
            candidates.append(Candidate(id: id, role: "secondary", window: secondary, planType: snapshot.planType))
        }
    }

    private static func nearest(to target: Int, in candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            abs((lhs.window.windowDurationMins ?? 0) - target)
                < abs((rhs.window.windowDurationMins ?? 0) - target)
        }
    }

    private static func makeWindow(_ candidate: Candidate) -> CodexQuotaWindow {
        let minutes = candidate.window.windowDurationMins ?? 0
        return CodexQuotaWindow(
            id: "\(candidate.id)-\(candidate.role)-\(minutes)",
            sourceID: candidate.id,
            label: windowLabel(minutes: minutes),
            usedPercent: min(100, max(0, candidate.window.usedPercent ?? 0)),
            durationMinutes: minutes,
            resetsAt: candidate.window.resetsAt
        )
    }

    private static func windowLabel(minutes: Int) -> String {
        if (4 * 60...6 * 60).contains(minutes) { return "5小时" }
        if (6 * 24 * 60...8 * 24 * 60).contains(minutes) { return "周" }
        if minutes >= 28 * 24 * 60 { return "月" }
        if minutes.isMultiple(of: 24 * 60) { return "\(minutes / (24 * 60))天" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }

}

private enum CodexQuotaError: LocalizedError {
    case server(String)
    case missingResult
    case noWindows

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .missingResult: return "Codex 未返回额度信息"
        case .noWindows: return "当前账户没有可用的 Codex 额度窗口"
        }
    }
}
