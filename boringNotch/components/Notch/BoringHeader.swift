//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

extension Notification.Name {
    static let resourceStatsPopoverChanged = Notification.Name(
        "com.boringNotch.resourceStatsPopoverChanged"
    )
}

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        ResourceStatsPill()
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

struct ClosedResourceStatsView: View {
    @ObservedObject private var resources = ResourceStatsViewModel.shared
    @ObservedObject private var tokens = CodexTokenStatsViewModel.shared
    @Default(.resourceNotchLayout) private var layout
    let centerWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            leadingStats
                .frame(width: leadingWidth, alignment: .trailing)

            Rectangle()
                .fill(.black)
                .frame(width: centerWidth)

            trailingStats
                .frame(width: trailingWidth, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.gray)
        .frame(height: 26)
        .onAppear {
            resources.startRefreshing()
            resources.refreshCodexIfNeeded()
        }
        .accessibilityLabel(
            "Codex 额度 \(resources.codexSummary)，内存已用 \(resources.memorySummary)，今日 Token \(tokens.todaySummary)"
        )
    }

    @ViewBuilder
    private var leadingStats: some View {
        switch layout {
        case .compact:
            Text("额度 \(resources.codexRemainingPercentSummary)")
                .monospacedDigit()
        case .standard:
            HStack(spacing: 4) {
                Image(systemName: "terminal.fill")
                Text(resources.codexSummary)
                    .monospacedDigit()
                staleIndicator
            }
        case .enhanced:
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                VStack(alignment: .trailing, spacing: 0) {
                    Text(resources.codexSummary)
                    Text(resources.dailyBudgetCompactSummary)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                staleIndicator
            }
        }
    }

    @ViewBuilder
    private var trailingStats: some View {
        switch layout {
        case .compact:
            Text("内存 \(resources.memorySummary)")
                .monospacedDigit()
        case .standard:
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                Text(resources.memorySummary)
                    .monospacedDigit()
            }
        case .enhanced:
            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                VStack(alignment: .leading, spacing: 0) {
                    Text("内存 \(resources.memorySummary)")
                    Text(resources.compactEstimatedQuotaRemainingSummary)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var staleIndicator: some View {
        if resources.isCodexStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var leadingWidth: CGFloat {
        switch layout {
        case .compact: return 58
        case .standard: return 92
        case .enhanced: return 152
        }
    }

    private var trailingWidth: CGFloat {
        switch layout {
        case .compact: return 54
        case .standard: return 72
        case .enhanced: return 132
        }
    }
}

private struct ResourceStatsPill: View {
    @ObservedObject private var model = ResourceStatsViewModel.shared
    @ObservedObject private var tokens = CodexTokenStatsViewModel.shared
    @State private var showingDetails = false
    @State private var dismissDetailsTask: Task<Void, Never>?

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                metric(icon: "terminal.fill", value: model.codexSummary)

                if model.isCodexStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                Divider()
                    .frame(height: 13)
                    .overlay(Color.gray.opacity(0.45))

                metric(icon: "memorychip", value: model.memorySummary)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                Capsule().fill(Color(nsColor: .secondarySystemFill))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Codex 额度与系统内存")
        .accessibilityLabel("Codex 额度 \(model.codexSummary)，内存已用 \(model.memorySummary)")
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            ResourceStatsDetailView(model: model)
                .onHover { hovering in
                    dismissDetailsTask?.cancel()
                    guard !hovering else { return }
                    dismissDetailsTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        showingDetails = false
                    }
                }
        }
        .onChange(of: showingDetails) { _, isPresented in
            NotificationCenter.default.post(
                name: .resourceStatsPopoverChanged,
                object: isPresented
            )
        }
        .onAppear {
            model.startRefreshing()
            model.refreshCodexIfNeeded()
        }
        .onDisappear {
            dismissDetailsTask?.cancel()
            NotificationCenter.default.post(
                name: .resourceStatsPopoverChanged,
                object: false
            )
        }
    }

    private func metric(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
            Text(value)
                .monospacedDigit()
                .frame(minWidth: 25, alignment: .trailing)
        }
    }
}

private struct ResourceStatsDetailView: View {
    @ObservedObject var model: ResourceStatsViewModel
    @ObservedObject private var tokens = CodexTokenStatsViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Codex 与内存", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(model.isRefreshingCodex ? .degrees(360) : .zero)
                        .animation(
                            model.isRefreshingCodex
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: model.isRefreshingCodex
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingCodex)
                .help("刷新")
            }

            if let quota = model.codexQuota {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Codex 额度", systemImage: "terminal.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(quota.planTier.displayName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    if case .plus = quota.planTier, let session = quota.session {
                        quotaRow("5 小时额度", window: session)
                    } else if case .pro = quota.planTier, let weekly = quota.weekly {
                        quotaRow("周额度", window: weekly)
                    } else {
                        Text(unavailableQuotaMessage(for: quota.planTier))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label(model.quotaForecastSummary, systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(
                        "预计剩余额度：\(model.estimatedQuotaRemainingSummary)",
                        systemImage: "gauge.medium"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Label(
                        "估算区间：\(model.quotaEstimateRangeSummary) · \(model.quotaEstimateConfidenceSummary)",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if model.isCodexStale {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("额度更新失败，正在显示上次数据", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if let error = model.codexError {
                                Text(error)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let error = model.codexError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 Codex 额度…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("今日 Token", systemImage: "number")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(tokens.todaySummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let today = tokens.today {
                    Text(
                        "输入 \(CodexTokenStatsViewModel.compactCount(today.inputTokens)) · "
                            + "输出 \(CodexTokenStatsViewModel.compactCount(today.outputTokens)) · "
                            + "缓存 \(CodexTokenStatsViewModel.compactCount(today.cachedInputTokens))"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else if tokens.isScanning {
                    Text("正在统计本机 Codex 会话…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("系统内存", systemImage: "memorychip")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("已用 \(Int(model.memoryUsedPercent.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(memoryColor)
                }
                ProgressView(value: model.memoryUsedFraction)
                    .tint(memoryColor)
                Text(model.formattedMemoryUsage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let updated = model.lastCodexUpdate {
                HStack(spacing: 4) {
                    Text("额度更新于")
                    Text(updated, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private func quotaRow(_ title: String, window: CodexQuotaWindow) -> some View {
        let remaining = window.remainingPercent
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text("剩余 \(Int(remaining.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quotaColor(remaining))
            }
            ProgressView(value: remaining / 100)
                .tint(quotaColor(remaining))
            if let reset = window.resetsAt {
                HStack(spacing: 4) {
                    Text("重置")
                    Text(reset, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func quotaColor(_ remaining: Double) -> Color {
        if remaining <= 20 { return .red }
        if remaining <= 45 { return .yellow }
        return .green
    }

    private func unavailableQuotaMessage(for plan: CodexPlanTier) -> String {
        switch plan {
        case .plus: return "5 小时额度暂不可用"
        case .pro: return "周额度暂不可用"
        case .unknown: return "暂不支持当前 Codex 套餐"
        }
    }

    private var memoryColor: Color {
        if model.memoryUsedPercent >= 85 { return .red }
        if model.memoryUsedPercent >= 70 { return .yellow }
        return .green
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
