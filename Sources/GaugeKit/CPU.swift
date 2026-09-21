// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import IOKit

public struct CoreLoad: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case performance = "P", efficiency = "E", unknown = "" }
    public let id: Int
    public let kind: Kind
    /// Apple's own name for the cluster — "Super" and "Efficiency" on an M5,
    /// "Performance" and "Efficiency" on earlier chips. Read from sysctl rather
    /// than hard-coded, because Apple has changed it between generations.
    public var clusterName: String = ""
    public let user: Double
    public let system: Double
    public let nice: Double

    public init(id: Int, kind: Kind, clusterName: String = "",
                user: Double, system: Double, nice: Double) {
        self.id = id
        self.kind = kind
        self.clusterName = clusterName
        self.user = user
        self.system = system
        self.nice = nice
    }

    public var total: Double { (user + system + nice).clamped(to: 0...1) }

    /// "Super 3" — how the core should be labelled in a list.
    public var label: String {
        clusterName.isEmpty ? "Core \(id)" : "\(clusterName) \(id)"
    }
}

public struct CPUSnapshot: Sendable {
    public var user: Double = 0
    public var system: Double = 0
    public var nice: Double = 0
    public var idle: Double = 1
    public var cores: [CoreLoad] = []
    public var loadAverage: (one: Double, five: Double, fifteen: Double) = (0, 0, 0)
    public var uptime: TimeInterval = 0
    public var processCount: Int = 0
    public var threadCount: Int = 0

    public var total: Double { (user + system + nice).clamped(to: 0...1) }
    public var performanceLoad: Double { Self.average(of: cores.filter { $0.kind == .performance }) }
    public var efficiencyLoad: Double { Self.average(of: cores.filter { $0.kind == .efficiency }) }

    private static func average(of cores: [CoreLoad]) -> Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.total } / Double(cores.count)
    }
}

public final class CPUMonitor: @unchecked Sendable {
    private var previousTicks: [[UInt32]] = []
    private let coreKinds: [CoreLoad.Kind]

    public let coreCount: Int
    public let performanceCoreCount: Int
    public let efficiencyCoreCount: Int
    public let brand: String
    /// Cluster names as the system reports them, fastest first.
    public let performanceClusterName: String
    public let efficiencyClusterName: String

    public init() {
        coreCount = Int(sysctlValue("hw.logicalcpu") ?? 1)
        brand = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "CPU"

        // perflevel0 is always the fastest cluster, and the system publishes
        // its own name for it: "Super" on an M5, "Performance" before that.
        let level0 = Int(sysctlValue("hw.perflevel0.logicalcpu") ?? 0)
        let level1 = Int(sysctlValue("hw.perflevel1.logicalcpu") ?? 0)
        performanceClusterName = sysctlString("hw.perflevel0.name") ?? "Performance"
        efficiencyClusterName = sysctlString("hw.perflevel1.name") ?? "Efficiency"

        if level0 > 0 && level1 > 0 {
            performanceCoreCount = level0
            efficiencyCoreCount = level1
            // The device tree states each core's cluster directly. Fall back to
            // the usual efficiency-first layout only if it cannot be read.
            coreKinds = Self.clusterTypesFromDeviceTree(coreCount: coreCount)
                ?? (Array(repeating: .efficiency, count: level1)
                    + Array(repeating: .performance, count: level0))
        } else {
            performanceCoreCount = coreCount
            efficiencyCoreCount = 0
            coreKinds = Array(repeating: .unknown, count: coreCount)
        }
    }

    /// Each `cpuN` node in the IORegistry carries a `cluster-type` of "E" or
    /// "P" and a `logical-cpu-id` that matches the index host_processor_info
    /// uses, which removes the need to guess how the clusters are ordered.
    private static func clusterTypesFromDeviceTree(coreCount: Int) -> [CoreLoad.Kind]? {
        guard coreCount > 0,
              let matching = IOServiceMatching("IOPlatformDevice") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var kinds = [CoreLoad.Kind](repeating: .unknown, count: coreCount)
        var found = 0

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)
            guard name.hasPrefix("cpu"), name != "cpus" else { continue }

            guard let typeData = IORegistryEntryCreateCFProperty(
                    entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data,
                  let letter = String(data: typeData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).first
            else { continue }

            guard let idData = IORegistryEntryCreateCFProperty(
                    entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data
            else { continue }
            let index = idData.reduce(0) { Int($1) << 8 | $0 }   // little-endian
            guard index >= 0, index < coreCount else { continue }

            kinds[index] = letter == "P" ? .performance : .efficiency
            found += 1
        }
        return found == coreCount ? kinds : nil
    }

    public func sample() -> CPUSnapshot {
        var snapshot = CPUSnapshot()

        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                          &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let info = infoArray else {
            snapshot.loadAverage = Self.loadAverages()
            snapshot.uptime = Self.uptime()
            return snapshot
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * states
            ticks.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }

        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else {
            // First sample has no baseline to diff against.
            snapshot.loadAverage = Self.loadAverages()
            snapshot.uptime = Self.uptime()
            snapshot.processCount = Self.processCount()
            return snapshot
        }

        var totals = (user: 0.0, system: 0.0, nice: 0.0, idle: 0.0)
        for core in 0..<ticks.count {
            // Tick counters are 32-bit and wrap; &- keeps the delta correct.
            let delta = (0..<4).map { Double(ticks[core][$0] &- previousTicks[core][$0]) }
            let sum = delta.reduce(0, +)
            guard sum > 0 else {
                snapshot.cores.append(CoreLoad(id: core, kind: kind(for: core),
                                               clusterName: clusterName(for: core),
                                               user: 0, system: 0, nice: 0))
                continue
            }
            let user = delta[0] / sum, system = delta[1] / sum, idle = delta[2] / sum, nice = delta[3] / sum
            totals.user += user; totals.system += system; totals.nice += nice; totals.idle += idle
            snapshot.cores.append(CoreLoad(id: core, kind: kind(for: core),
                                           clusterName: clusterName(for: core),
                                           user: user, system: system, nice: nice))
        }

        let n = Double(max(1, ticks.count))
        snapshot.user = totals.user / n
        snapshot.system = totals.system / n
        snapshot.nice = totals.nice / n
        snapshot.idle = totals.idle / n
        snapshot.loadAverage = Self.loadAverages()
        snapshot.uptime = Self.uptime()
        snapshot.processCount = Self.processCount()
        // Thread totals need a walk over every process, which ProcessMonitor
        // already does; the hub fills the count in from there.
        return snapshot
    }

    private func kind(for index: Int) -> CoreLoad.Kind {
        index < coreKinds.count ? coreKinds[index] : .unknown
    }

    private func clusterName(for index: Int) -> String {
        switch kind(for: index) {
        case .performance: performanceClusterName
        case .efficiency: efficiencyClusterName
        case .unknown: ""
        }
    }

    // MARK: Host facts

    static func loadAverages() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    /// One syscall: asking for the size of the pid list is enough to count it,
    /// with no per-process round trips.
    static func processCount() -> Int {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<pid_t>.stride
    }
}

// MARK: - sysctl helpers

func sysctlValue(_ name: String) -> Int64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    if size == MemoryLayout<Int32>.size {
        var value: Int32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int64(value)
    }
    var value: Int64 = 0
    var valueSize = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &valueSize, nil, 0) == 0 else { return nil }
    return value
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
