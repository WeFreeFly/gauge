// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit

/// Clock speeds for the CPU clusters and the GPU.
public struct FrequencySnapshot: Sendable, Equatable {
    /// Average clock while the unit was actually running, in MHz. Nil when the
    /// unit stayed idle for the whole interval — there is no speed to report.
    public var efficiencyMHz: Double?
    public var performanceMHz: Double?
    public var gpuMHz: Double?

    /// Share of the interval the unit spent out of idle, 0…1.
    public var efficiencyActive: Double = 0
    public var performanceActive: Double = 0
    public var gpuActive: Double = 0

    public var maximumEfficiencyMHz: Double = 0
    public var maximumPerformanceMHz: Double = 0
    public var maximumGPUMHz: Double = 0

    public init() {}
}

/// Reads DVFS residency through IOReport and turns it into a clock speed.
///
/// Apple Silicon publishes no current frequency. What it publishes is how long
/// each cluster spent in each performance state; multiplying that by the state
/// table in the power manager gives the average clock over the interval, which
/// is what every tool that reports a frequency here is doing.
///
/// IOReport is private, so every entry point is resolved by name and the whole
/// monitor reports nothing rather than failing if one is missing.
public final class FrequencyMonitor: @unchecked Sendable {
    // MARK: Private API surface

    private typealias CopyChannelsInGroup =
        @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription =
        @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                        UInt64, CFTypeRef?) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSamples =
        @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias ChannelGetSubGroup = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let copyChannels: CopyChannelsInGroup
    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let stateCount: StateGetCount
    private let stateName: StateGetNameForIndex
    private let stateResidency: StateGetResidency
    private let channelSubGroup: ChannelGetSubGroup
    private let channelName: ChannelGetChannelName

    private let cpuSubscription: CFMutableDictionary
    private let cpuChannels: CFMutableDictionary
    private let gpuSubscription: CFMutableDictionary
    private let gpuChannels: CFMutableDictionary

    private var previousCPU: CFDictionary?
    private var previousGPU: CFDictionary?
    /// Held so the subscriptions keep pointing at live dictionaries.
    private let cpuChannelList: CFMutableDictionary
    private let gpuChannelList: CFMutableDictionary

    /// State tables from the power manager, in MHz.
    private let efficiencyFrequencies: [Double]
    private let performanceFrequencies: [Double]
    private let gpuFrequencies: [Double]

    public init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let channelsSym = dlsym(handle, "IOReportCopyChannelsInGroup"),
              let subscribeSym = dlsym(handle, "IOReportCreateSubscription"),
              let samplesSym = dlsym(handle, "IOReportCreateSamples"),
              let deltaSym = dlsym(handle, "IOReportCreateSamplesDelta"),
              let countSym = dlsym(handle, "IOReportStateGetCount"),
              let nameSym = dlsym(handle, "IOReportStateGetNameForIndex"),
              let residencySym = dlsym(handle, "IOReportStateGetResidency"),
              let subGroupSym = dlsym(handle, "IOReportChannelGetSubGroup"),
              let channelNameSym = dlsym(handle, "IOReportChannelGetChannelName")
        else { return nil }

        copyChannels = unsafeBitCast(channelsSym, to: CopyChannelsInGroup.self)
        createSamples = unsafeBitCast(samplesSym, to: CreateSamples.self)
        createDelta = unsafeBitCast(deltaSym, to: CreateSamplesDelta.self)
        stateCount = unsafeBitCast(countSym, to: StateGetCount.self)
        stateName = unsafeBitCast(nameSym, to: StateGetNameForIndex.self)
        stateResidency = unsafeBitCast(residencySym, to: StateGetResidency.self)
        channelSubGroup = unsafeBitCast(subGroupSym, to: ChannelGetSubGroup.self)
        channelName = unsafeBitCast(channelNameSym, to: ChannelGetChannelName.self)

        let subscribe = unsafeBitCast(subscribeSym, to: CreateSubscription.self)

        guard let cpuList = copyChannels("CPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let gpuList = copyChannels("GPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        // The ownership of the out-parameter is not documented anywhere, and
        // guessing wrong crashes rather than leaks. These two dictionaries
        // live for the process's lifetime either way, so they are taken
        // unretained: at worst that holds one allocation that was never going
        // to be freed.
        var cpuSubscribed: Unmanaged<CFMutableDictionary>?
        var gpuSubscribed: Unmanaged<CFMutableDictionary>?
        guard let cpuSub = subscribe(nil, cpuList, &cpuSubscribed, 0, nil)?.takeUnretainedValue(),
              let gpuSub = subscribe(nil, gpuList, &gpuSubscribed, 0, nil)?.takeUnretainedValue(),
              let cpuSubscribedList = cpuSubscribed?.takeUnretainedValue(),
              let gpuSubscribedList = gpuSubscribed?.takeUnretainedValue()
        else { return nil }

        cpuChannelList = cpuList
        gpuChannelList = gpuList
        cpuSubscription = cpuSub
        cpuChannels = cpuSubscribedList
        gpuSubscription = gpuSub
        gpuChannels = gpuSubscribedList

        let tables = Self.frequencyTables()
        efficiencyFrequencies = tables.efficiency
        performanceFrequencies = tables.performance
        gpuFrequencies = tables.gpu

        guard !efficiencyFrequencies.isEmpty || !performanceFrequencies.isEmpty else { return nil }
    }

    // MARK: Sampling

    public func sample() -> FrequencySnapshot {
        var snapshot = FrequencySnapshot()
        snapshot.maximumEfficiencyMHz = efficiencyFrequencies.last ?? 0
        snapshot.maximumPerformanceMHz = performanceFrequencies.last ?? 0
        snapshot.maximumGPUMHz = gpuFrequencies.last ?? 0

        if let delta = delta(subscription: cpuSubscription, channels: cpuChannels, previous: &previousCPU) {
            for channel in Self.channels(in: delta) {
                guard subGroup(of: channel) == "CPU Complex Performance States" else { continue }
                switch name(of: channel) {
                case "ECPU":
                    let result = weighted(channel, frequencies: efficiencyFrequencies)
                    snapshot.efficiencyMHz = result.frequency
                    snapshot.efficiencyActive = result.active
                case "PCPU":
                    let result = weighted(channel, frequencies: performanceFrequencies)
                    snapshot.performanceMHz = result.frequency
                    snapshot.performanceActive = result.active
                default:
                    continue
                }
            }
        }

        if let delta = delta(subscription: gpuSubscription, channels: gpuChannels, previous: &previousGPU) {
            for channel in Self.channels(in: delta) {
                guard subGroup(of: channel) == "GPU Performance States",
                      name(of: channel) == "GPUPH" else { continue }
                let result = weighted(channel, frequencies: gpuFrequencies)
                snapshot.gpuMHz = result.frequency
                snapshot.gpuActive = result.active
            }
        }
        return snapshot
    }

    private func delta(subscription: CFMutableDictionary, channels: CFMutableDictionary,
                       previous: inout CFDictionary?) -> CFDictionary? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = current }
        guard let earlier = previous else { return nil }   // first pass has no baseline
        return createDelta(earlier, current, nil)?.takeRetainedValue()
    }

    /// Residency-weighted mean over the states that are not idle. Including
    /// idle would report a low clock for a machine doing nothing, which is not
    /// the same as a slow clock.
    private func weighted(_ channel: CFDictionary,
                          frequencies: [Double]) -> (frequency: Double?, active: Double) {
        let count = Int(stateCount(channel))
        guard count > 0, !frequencies.isEmpty else { return (nil, 0) }

        var idleResidency = 0.0
        var activeResidency = 0.0
        var total = 0.0
        var frequencyIndex = 0

        for index in 0..<count {
            let residency = Double(stateResidency(channel, Int32(index)))
            guard residency >= 0 else { continue }
                let label = stateName(channel, Int32(index))?.takeUnretainedValue() as String? ?? ""

            if Self.isIdleState(label) {
                idleResidency += residency
                continue
            }
            // States past the end of the table are boost steps the power
            // manager does not publish a frequency for; the top one is the
            // closest honest answer.
            let frequency = frequencies[min(frequencyIndex, frequencies.count - 1)]
            frequencyIndex += 1
            activeResidency += residency
            total += residency * frequency
        }

        let overall = idleResidency + activeResidency
        let active = overall > 0 ? activeResidency / overall : 0
        let frequency = activeResidency > 0 ? total / activeResidency : nil
        return (frequency, active)
    }

    private static func isIdleState(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper == "IDLE" || upper == "OFF" || upper == "DOWN" || upper.hasPrefix("IDLE")
    }

    private func subGroup(of channel: CFDictionary) -> String {
        channelSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
    }

    private func name(of channel: CFDictionary) -> String {
        channelName(channel)?.takeUnretainedValue() as String? ?? ""
    }

    private static func channels(in delta: CFDictionary) -> [CFDictionary] {
        guard let raw = CFDictionaryGetValue(delta, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque())
        else { return [] }
        let array = unsafeBitCast(raw, to: CFArray.self)
        return (array as? [CFDictionary]) ?? []
    }

    // MARK: Frequency tables

    /// The power manager publishes one state table per clock domain. The
    /// "-sram" CPU tables hold kilohertz; the GPU table holds hertz.
    public static func frequencyTables() -> (efficiency: [Double], performance: [Double], gpu: [Double]) {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleARMIODevice"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return ([], [], []) }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS,
                  String(cString: nameBuffer) == "pmgr" else { continue }

            func table(_ key: String, divisor: Double) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                                 kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }
                var values: [Double] = []
                let pairs = data.count / 8
                for index in 0..<pairs {
                    let raw = data.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self)
                    }
                    let megahertz = Double(raw) / divisor
                    if megahertz > 1 { values.append(megahertz) }   // drop the "off" entry
                }
                return values
            }

            return (efficiency: table("voltage-states1-sram", divisor: 1_000),
                    performance: table("voltage-states5-sram", divisor: 1_000),
                    gpu: table("voltage-states9", divisor: 1_000_000))
        }
        return ([], [], [])
    }
}
