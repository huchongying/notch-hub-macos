//
//  HardwareStatsViewModel.swift
//  boringNotch
//

import AppKit
import Darwin
import Combine
import Foundation
import Metal

struct HardwareMetricSample: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let cpuPercent: Double
    let memoryPercent: Double
    let downloadMegabytesPerSecond: Double
    let uploadMegabytesPerSecond: Double

    var id: Date { timestamp }
}

@MainActor
final class HardwareStatsViewModel: ObservableObject {
    static let shared = HardwareStatsViewModel()

    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var loadAverage = "--"
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskAvailableBytes: Int64 = 0
    @Published private(set) var diskTotalBytes: Int64 = 0
    @Published private(set) var thermalState = "正常"
    @Published private(set) var uptime = "--"
    @Published private(set) var history: [HardwareMetricSample] = []
    @Published private(set) var samplingSummary = "每5秒"

    let cpuName: String
    let coreSummary: String
    let gpuName: String

    private var refreshTask: Task<Void, Never>?
    private var previousCPUTicks: CPUTicks?
    private var previousNetwork: NetworkCounters?
    private var previousNetworkDate: Date?
    private var refreshCount = 0
    private var dashboardVisible = true
    private var dashboardOccluded = false
    private var systemActive = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        cpuName = Self.sysctlString("machdep.cpu.brand_string")
            ?? Self.sysctlString("hw.model")
            ?? "未知处理器"
        coreSummary = "\(ProcessInfo.processInfo.processorCount) 核心"
        gpuName = MTLCreateSystemDefaultDevice()?.name ?? "未知 GPU"
        observeSystemState()
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        update()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.currentSamplingInterval
                self.samplingSummary = interval >= 15 ? "每15秒" : "每5秒"
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, self.systemActive else { continue }
                self.update()
            }
        }
    }

    func setDashboardState(visible: Bool, occluded: Bool) {
        let becameVisible = visible && (!dashboardVisible || dashboardOccluded)
        dashboardVisible = visible
        dashboardOccluded = occluded
        if becameVisible {
            previousCPUTicks = nil
            previousNetwork = nil
            previousNetworkDate = nil
            update()
        }
    }

    private var currentSamplingInterval: Double {
        guard systemActive else { return 15 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 15
        case .fair: return 15
        case .nominal:
            return ProcessInfo.processInfo.isLowPowerModeEnabled
                || !dashboardVisible
                || dashboardOccluded ? 15 : 5
        @unknown default: return 15
        }
    }

    private func observeSystemState() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemActive = false }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemActive = false }
        })
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemActive = true
                    self.previousCPUTicks = nil
                    self.previousNetwork = nil
                    self.previousNetworkDate = nil
                    self.update()
                }
            })
        }
    }

    private func update() {
        updateCPU()
        updateNetwork()
        updateSystemState()
        refreshCount += 1
        if refreshCount == 1 || refreshCount.isMultiple(of: 5) {
            updateDisk()
        }
        recordHistory()
    }

    private func updateCPU() {
        guard let current = Self.readCPUTicks() else { return }
        if let previousCPUTicks {
            let active = current.active &- previousCPUTicks.active
            let idle = current.idle &- previousCPUTicks.idle
            let total = active + idle
            if total > 0 {
                cpuUsage = min(1, max(0, Double(active) / Double(total)))
            }
        }
        previousCPUTicks = current

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            loadAverage = String(format: "%.2f · %.2f · %.2f", loads[0], loads[1], loads[2])
        }
    }

    private func updateNetwork() {
        let current = Self.readNetworkCounters()
        let now = Date()
        if let previousNetwork, let previousNetworkDate {
            let interval = max(0.1, now.timeIntervalSince(previousNetworkDate))
            let received = current.received >= previousNetwork.received
                ? current.received - previousNetwork.received : 0
            let sent = current.sent >= previousNetwork.sent
                ? current.sent - previousNetwork.sent : 0
            downloadBytesPerSecond = UInt64(Double(received) / interval)
            uploadBytesPerSecond = UInt64(Double(sent) / interval)
        }
        previousNetwork = current
        previousNetworkDate = now
    }

    private func updateDisk() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        )
        diskAvailableBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotalBytes = Int64(values?.volumeTotalCapacity ?? 0)
    }

    private func updateSystemState() {
        thermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "轻微升温"
        case .serious: "温度较高"
        case .critical: "严重过热"
        @unknown default: "未知"
        }

        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        uptime = days > 0 ? "\(days)天 \(hours)小时" : "\(hours)小时"
    }

    private func recordHistory() {
        let now = Date()
        history.append(
            HardwareMetricSample(
                timestamp: now,
                cpuPercent: cpuUsage * 100,
                memoryPercent: ResourceStatsViewModel.shared.memoryUsedPercent,
                downloadMegabytesPerSecond: Double(downloadBytesPerSecond) / 1_000_000,
                uploadMegabytesPerSecond: Double(uploadBytesPerSecond) / 1_000_000
            )
        )
        let cutoff = now.addingTimeInterval(-30 * 60)
        history = Array(history.drop { $0.timestamp < cutoff }.suffix(900))
    }

    nonisolated private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(
            active: UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3),
            idle: UInt64(ticks.2)
        )
    }

    nonisolated private static func readNetworkCounters() -> NetworkCounters {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return .zero }
        defer { freeifaddrs(pointer) }

        var result = NetworkCounters.zero
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let dataPointer = interface.ifa_data
            else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            result.received += UInt64(data.ifi_ibytes)
            result.sent += UInt64(data.ifi_obytes)
        }
        return result
    }

    nonisolated private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

private struct CPUTicks {
    let active: UInt64
    let idle: UInt64
}

private struct NetworkCounters {
    var received: UInt64
    var sent: UInt64

    static let zero = NetworkCounters(received: 0, sent: 0)
}
