// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public struct MemorySnapshot: Sendable {
    public var total: Double = 0
    public var appMemory: Double = 0
    public var wired: Double = 0
    public var compressed: Double = 0
    public var cachedFiles: Double = 0
    public var free: Double = 0
    public var swapTotal: Double = 0
    public var swapUsed: Double = 0
    public var pressure: MemoryPressure = .normal
    /// Page-ins/outs since boot, for the "is it actually swapping" question.
    public var pageIns: UInt64 = 0
    public var pageOuts: UInt64 = 0
    public var swapIns: UInt64 = 0
    public var swapOuts: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    public var used: Double { appMemory + wired + compressed }
    public var usedFraction: Double { total > 0 ? (used / total).clamped(to: 0...1) : 0 }
    public var swapUsedFraction: Double { swapTotal > 0 ? (swapUsed / swapTotal).clamped(to: 0...1) : 0 }

    /// What Activity Monitor draws in its pressure graph — it tracks wired plus
    /// compressed rather than total usage, which is why a machine can sit at
    /// 90% used and still report green.
    public var pressureFraction: Double {
        total > 0 ? ((wired + compressed) / total).clamped(to: 0...1) : 0
    }
}

public enum MemoryPressure: Int, Sendable, CaseIterable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Mirrors `struct xsw_usage` from <sys/sysctl.h>.
private struct SwapUsage {
    var total: UInt64 = 0
    var available: UInt64 = 0
    var used: UInt64 = 0
    var pageSize: UInt32 = 0
    var encrypted: Int32 = 0
}

public final class MemoryMonitor: @unchecked Sendable {
    public let physicalMemory: Double

    public init() {
        physicalMemory = Double(sysctlValue("hw.memsize") ?? 0)
    }

    public func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snapshot }

        let page = Double(vm_kernel_page_size)
        // "internal" pages are anonymous memory owned by apps; purgeable pages
        // inside that total are caches the system can reclaim, so Activity
        // Monitor subtracts them and counts them as cached instead.
        let internalPages = Double(stats.internal_page_count)
        let purgeablePages = Double(stats.purgeable_count)
        let externalPages = Double(stats.external_page_count)

        snapshot.appMemory = max(0, (internalPages - purgeablePages)) * page
        snapshot.wired = Double(stats.wire_count) * page
        snapshot.compressed = Double(stats.compressor_page_count) * page
        snapshot.cachedFiles = (externalPages + purgeablePages) * page
        snapshot.free = Double(stats.free_count - stats.speculative_count) * page
        snapshot.pageIns = stats.pageins
        snapshot.pageOuts = stats.pageouts
        snapshot.swapIns = stats.swapins
        snapshot.swapOuts = stats.swapouts

        var swap = SwapUsage()
        var swapSize = MemoryLayout<SwapUsage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snapshot.swapTotal = Double(swap.total)
            snapshot.swapUsed = Double(swap.used)
        }

        if let level = sysctlValue("kern.memorystatus_vm_pressure_level"),
           let pressure = MemoryPressure(rawValue: Int(level)) {
            snapshot.pressure = pressure
        }
        return snapshot
    }
}
