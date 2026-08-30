//
//  HardwareDashboard.swift
//  boringNotch
//

import AppKit
import Charts
import Defaults
import SwiftUI

extension Notification.Name {
    static let showQuotaBudget = Notification.Name("com.boringNotch.showQuotaBudget")
}

final class HardwareDashboardWindowController: NSWindowController {
    static let shared = HardwareDashboardWindowController()
    private var occlusionObserver: NSObjectProtocol?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.title = "硬件监控"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 280, height: 320)
        panel.maxSize = NSSize(width: 620, height: 760)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        )
        panel.setFrameAutosaveName("BoringNotchHardwareDashboardResizableV2")
        let hostingView = NSHostingView(rootView: HardwareDashboardView())
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            Task { @MainActor in
                HardwareStatsViewModel.shared.setDashboardState(
                    visible: panel.isVisible,
                    occluded: !panel.occlusionState.contains(.visible)
                )
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showDashboard() {
        guard let window else { return }
        let restoredFrame = window.setFrameUsingName("BoringNotchHardwareDashboardResizableV2")
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !restoredFrame || !isOnScreen {
            positionAtDesktopEdge(window)
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        HardwareStatsViewModel.shared.setDashboardState(visible: true, occluded: false)
        ResourceStatsViewModel.shared.refreshCodexIfNeeded()
    }

    func toggleDashboard() {
        if window?.isVisible == true {
            window?.orderOut(nil)
            HardwareStatsViewModel.shared.setDashboardState(visible: false, occluded: true)
        } else {
            showDashboard()
        }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    private func positionAtDesktopEdge(_ window: NSWindow) {
        guard let frame = NSScreen.main?.visibleFrame else {
            window.center()
            return
        }
        window.setFrameOrigin(
            NSPoint(x: frame.maxX - window.frame.width - 24, y: frame.maxY - window.frame.height - 24)
        )
    }
}

struct HardwareDashboardView: View {
    @ObservedObject private var hardware = HardwareStatsViewModel.shared
    @ObservedObject private var resources = ResourceStatsViewModel.shared
    @ObservedObject private var tokens = CodexTokenStatsViewModel.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @Default(.hardwareDashboardModuleOrder) private var moduleOrder
    @Default(.hiddenHardwareDashboardModules) private var hiddenModules
    @State private var trendMode: TrendMode = .quota
    @State private var isEditingLayout = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("硬件监控", systemImage: "desktopcomputer")
                            .font(.headline)
                        Spacer()
                        Text("今日 \(tokens.todaySummary) Token")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditingLayout.toggle()
                            }
                        } label: {
                            Label(
                                isEditingLayout ? "完成" : "编辑布局",
                                systemImage: isEditingLayout ? "checkmark" : "slider.horizontal.3"
                            )
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .help(isEditingLayout ? "完成编辑" : "编辑模块布局")
                    }

                    if isEditingLayout {
                        layoutEditor
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        quotaBudgetSection
                            .id("quotaBudget")
                        ForEach(visibleModules) { module in
                            dashboardModule(module)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .onReceive(NotificationCenter.default.publisher(for: .showQuotaBudget)) { _ in
                isEditingLayout = false
                trendMode = .quota
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("quotaBudget", anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 280, minHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(10)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            hardware.startRefreshing()
            resources.startRefreshing()
            normalizeModuleOrder()
        }
    }

    @ViewBuilder
    private func dashboardModule(_ module: HardwareDashboardModule) -> some View {
        switch module {
        case .trends:
            trendSection
        case .processor:
            metricSection(title: module.title, icon: module.icon) {
                metricRow("型号", hardware.cpuName)
                metricRow("规格", hardware.coreSummary)
                progressRow("占用", value: hardware.cpuUsage, text: percent(hardware.cpuUsage))
                metricRow("系统负载", hardware.loadAverage)
            }
        case .graphicsMemory:
            metricSection(title: module.title, icon: module.icon) {
                metricRow("GPU", hardware.gpuName)
                progressRow(
                    "内存",
                    value: resources.memoryUsedFraction,
                    text: resources.formattedMemoryUsage
                )
                metricRow("内存压力", resources.memoryPressure)
                metricRow("压缩内存", bytes(resources.compressedMemoryBytes))
                metricRow(
                    "Swap",
                    "\(bytes(resources.swapUsedBytes)) / \(bytes(resources.swapTotalBytes))"
                )
            }
        case .storageNetwork:
            metricSection(title: module.title, icon: module.icon) {
                progressRow("磁盘", value: diskUsedFraction, text: diskSummary)
                metricRow("下载", "↓ \(rate(hardware.downloadBytesPerSecond))")
                metricRow("上传", "↑ \(rate(hardware.uploadBytesPerSecond))")
            }
        case .system:
            metricSection(title: module.title, icon: module.icon) {
                metricRow("温度状态", hardware.thermalState)
                metricRow("采样频率", hardware.samplingSummary)
                metricRow("电池", batterySummary)
                metricRow("电池健康", batteryHealthSummary)
                metricRow("循环次数", battery.cycleCount.map(String.init) ?? "暂不可用")
                metricRow("容量", batteryCapacitySummary)
                metricRow("运行时间", hardware.uptime)
            }
        case .codexTokens:
            metricSection(title: module.title, icon: module.icon) {
                if let today = tokens.today {
                    metricRow("本机总计", CodexTokenStatsViewModel.compactCount(today.totalTokens))
                    metricRow(
                        "输入 / 输出",
                        "\(CodexTokenStatsViewModel.compactCount(today.inputTokens)) / \(CodexTokenStatsViewModel.compactCount(today.outputTokens))"
                    )
                    metricRow("缓存输入", CodexTokenStatsViewModel.compactCount(today.cachedInputTokens))
                    metricRow("未归因估算", resources.unattributedTodaySummary)
                    if let updated = tokens.lastUpdated {
                        metricRow(
                            "统计更新",
                            freshnessText(updated, staleAfter: 15 * 60, error: tokens.errorMessage)
                        )
                    }
                } else {
                    Text("正在统计今日用量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quotaBudgetSection: some View {
        metricSection(title: "Codex 每日预算", icon: "gauge.with.dots.needle.50percent") {
            if let budget = resources.dailyBudget {
                progressRow(
                    "今日进度",
                    value: budget.usageRatio,
                    text: "\(resources.dailyBudgetPercentSummary) · \(resources.dailyBudgetProgressSummary)"
                )
                metricRow("今日剩余", resources.dailyBudgetRemainingSummary)
            } else {
                Text("正在学习额度与 Token 的换算关系")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            metricRow("周预计剩余", resources.estimatedQuotaRemainingSummary)
            metricRow("距离重置", resources.quotaResetCountdownSummary)
            if let updated = resources.lastCodexUpdate {
                metricRow(
                    "额度更新",
                    freshnessText(updated, staleAfter: 10 * 60, error: resources.codexError)
                )
            }

            if let quota = resources.codexQuota, !quota.allWindows.isEmpty {
                Divider().opacity(0.35)
                Text("全部额度窗口")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(quota.allWindows, id: \.id) { window in
                    metricRow(
                        window.sourceID == "default"
                            ? window.label
                            : "\(window.label) · \(window.sourceID)",
                        "剩余 \(Int(window.remainingPercent.rounded()))% · \(resetSummary(window.resetsAt))"
                    )
                }
            }

            Divider().opacity(0.35)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(tiboStatusColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resources.tiboResetSignal.title)
                        .font(.caption.weight(.medium))
                    Text(resources.tiboResetSignal.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if resources.isRefreshingTibo {
                    ProgressView().controlSize(.mini)
                }
            }

            HStack(spacing: 8) {
                if let checked = resources.lastTiboCheck {
                    Text("检查于 \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let sourceURL = resources.tiboResetSignal.sourceURL {
                    Link("查看来源", destination: sourceURL)
                        .font(.caption2.weight(.medium))
                }
            }
            if let success = resources.lastTiboSuccess {
                metricRow(
                    "最后成功",
                    freshnessText(success, staleAfter: 2 * 60 * 60, error: resources.tiboError)
                )
            } else if let error = resources.tiboError {
                metricRow("Tibo", "无成功数据 · \(error)")
            }
        }
    }

    private var tiboStatusColor: Color {
        switch resources.tiboResetSignal.kind {
        case .monitoring: return .gray
        case .possible: return .orange
        case .announced: return .yellow
        case .synchronized: return .green
        case .unavailable: return .red
        }
    }

    private func resetSummary(_ date: Date?) -> String {
        guard let date else { return "重置时间未知" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func freshnessText(_ date: Date, staleAfter: TimeInterval, error: String?) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if let error { return "已过期 · \(time) · \(error)" }
        return Date().timeIntervalSince(date) >= staleAfter ? "已过期 · \(time)" : time
    }

    private var layoutEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拖动模块调整顺序，关闭开关即可隐藏。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(orderedModules) { module in
                HStack(spacing: 9) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                    Label(module.title, systemImage: module.icon)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Toggle("", isOn: visibilityBinding(for: module))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(
                    Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(Rectangle())
                .draggable(module.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let rawValue = items.first,
                          let source = HardwareDashboardModule(rawValue: rawValue)
                    else {
                        return false
                    }
                    moveModule(source, before: module)
                    return true
                }
            }
        }
    }

    private var orderedModules: [HardwareDashboardModule] {
        let valid = moduleOrder.reduce(into: [HardwareDashboardModule]()) { result, module in
            if !result.contains(module) {
                result.append(module)
            }
        }
        return valid + HardwareDashboardModule.allCases.filter { !valid.contains($0) }
    }

    private var visibleModules: [HardwareDashboardModule] {
        orderedModules.filter { !hiddenModules.contains($0) }
    }

    private func visibilityBinding(for module: HardwareDashboardModule) -> Binding<Bool> {
        Binding(
            get: { !hiddenModules.contains(module) },
            set: { isVisible in
                var updated = hiddenModules.filter { $0 != module }
                if !isVisible {
                    updated.append(module)
                }
                hiddenModules = HardwareDashboardModule.allCases.filter { updated.contains($0) }
            }
        )
    }

    private func moveModule(
        _ source: HardwareDashboardModule,
        before target: HardwareDashboardModule
    ) {
        var updated = orderedModules
        guard source != target,
              let sourceIndex = updated.firstIndex(of: source),
              let targetIndex = updated.firstIndex(of: target)
        else {
            return
        }
        updated.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        updated.insert(source, at: max(0, insertionIndex))
        moduleOrder = updated
    }

    private func normalizeModuleOrder() {
        let normalized = orderedModules
        if moduleOrder != normalized {
            moduleOrder = normalized
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("历史趋势", selection: $trendMode) {
                ForEach(TrendMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch trendMode {
                case .quota:
                    Chart(resources.currentQuotaHistory) { sample in
                        LineMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("剩余额度", sample.remainingPercent)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.green)
                        PointMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("剩余额度", sample.remainingPercent)
                        )
                        .foregroundStyle(.green)
                    }
                    .chartYScale(domain: 0...100)
                    .overlay {
                        if resources.currentQuotaHistory.count < 2 {
                            Text("正在积累额度历史样本")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .hardware:
                    Chart {
                        ForEach(hardware.history) { sample in
                            LineMark(
                                x: .value("时间", sample.timestamp),
                                y: .value("百分比", sample.cpuPercent),
                                series: .value("指标", "CPU")
                            )
                            .foregroundStyle(by: .value("指标", "CPU"))
                            LineMark(
                                x: .value("时间", sample.timestamp),
                                y: .value("百分比", sample.memoryPercent),
                                series: .value("指标", "内存")
                            )
                            .foregroundStyle(by: .value("指标", "内存"))
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartForegroundStyleScale(["CPU": .blue, "内存": .orange])
                case .tokens:
                    Chart(Array(tokens.days.prefix(7).reversed())) { day in
                        BarMark(
                            x: .value("日期", day.day, unit: .day),
                            y: .value("Token（亿）", Double(day.totalTokens) / 100_000_000)
                        )
                        .foregroundStyle(.purple.gradient)
                    }
                }
            }
            .frame(height: 92)
            .chartXAxis(.hidden)

            if trendMode == .quota {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resources.quotaForecastSummary)
                    Text("预计剩余额度：\(resources.estimatedQuotaRemainingSummary)")
                    Text("估算区间：\(resources.quotaEstimateRangeSummary)")
                    Text(resources.quotaEstimateConfidenceSummary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
    }

    private func metricSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private func progressRow(_ title: String, value: Double, text: String) -> some View {
        VStack(spacing: 4) {
            metricRow(title, text)
            ProgressView(value: min(1, max(0, value)))
                .tint(value >= 0.85 ? .red : value >= 0.70 ? .yellow : .green)
        }
    }

    private var diskUsedFraction: Double {
        guard hardware.diskTotalBytes > 0 else { return 0 }
        return 1 - Double(hardware.diskAvailableBytes) / Double(hardware.diskTotalBytes)
    }

    private var diskSummary: String {
        "可用 \(bytes(hardware.diskAvailableBytes)) / \(bytes(hardware.diskTotalBytes))"
    }

    private var batterySummary: String {
        let state = battery.isCharging ? "充电中" : battery.isPluggedIn ? "已接电源" : "使用电池"
        return "\(Int(battery.levelBattery))% · \(state)"
    }

    private var batteryHealthSummary: String {
        guard let health = battery.healthPercent else { return "暂不可用" }
        return "\(Int(health.rounded()))%"
    }

    private var batteryCapacitySummary: String {
        guard let full = battery.fullChargeCapacity, let design = battery.designCapacity else {
            return "暂不可用"
        }
        return "\(full) / \(design) mAh"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func rate(_ bytes: UInt64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))/秒"
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

private enum TrendMode: String, CaseIterable, Identifiable {
    case quota
    case hardware
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quota: "额度"
        case .hardware: "硬件"
        case .tokens: "Token"
        }
    }
}
