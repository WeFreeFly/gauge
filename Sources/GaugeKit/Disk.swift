// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit
import IOKit.storage

public struct VolumeInfo: Identifiable, Sendable, Hashable {
    public let id: String          // BSD name when known, else the mount path
    public let name: String
    public let path: String
    public let total: Double
    public let free: Double
    public let isRemovable: Bool
    public let isInternal: Bool

    public var used: Double { max(0, total - free) }
    public var usedFraction: Double { total > 0 ? (used / total).clamped(to: 0...1) : 0 }
}

public struct DiskActivity: Sendable, Hashable {
    public var readRate: Double = 0          // bytes/sec
    public var writeRate: Double = 0
    public var readTotal: Double = 0         // bytes since boot
    public var writeTotal: Double = 0
    public var readOperations: UInt64 = 0
    public var writeOperations: UInt64 = 0
}

public struct DiskSnapshot: Sendable {
    public var volumes: [VolumeInfo] = []
    public var activity = DiskActivity()
    /// The volume the OS boots from — what a one-line menu bar readout should show.
    public var bootVolume: VolumeInfo? { volumes.first { $0.path == "/" } ?? volumes.first }
}

public final class DiskMonitor: @unchecked Sendable {
    private var previousRead: UInt64?
    private var previousWrite: UInt64?
    private var previousTimestamp: Date?
    private var cachedVolumes: [VolumeInfo] = []
    private var volumesReadAt: Date?

    /// Enumerating volumes touches the file system and takes an order of
    /// magnitude longer than reading the byte counters; capacities do not
    /// change fast enough to justify that on every tick.
    public var volumeRefreshInterval: TimeInterval = 10

    public init() {}

    public func sample(live: Bool = true) -> DiskSnapshot {
        var snapshot = DiskSnapshot()
        let stale = volumesReadAt.map { Date().timeIntervalSince($0) >= volumeRefreshInterval } ?? true
        if live || stale || cachedVolumes.isEmpty {
            cachedVolumes = mountedVolumes()
            volumesReadAt = Date()
        }
        snapshot.volumes = cachedVolumes
        snapshot.activity = blockStorageActivity()
        return snapshot
    }

    // MARK: Capacity

    private func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes])
        else { return [] }

        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            // "Important usage" is what Finder shows: it counts purgeable space
            // the system would free on demand, so it is larger than the raw
            // figure and matches what people expect. Some volumes report 0 for
            // it even when they have free space, so fall back in that case
            // rather than drawing them as full.
            let importantUsage = values.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? 0
            let plain = Double(values.volumeAvailableCapacity ?? 0)
            let free = importantUsage > 0 ? importantUsage : plain

            return VolumeInfo(
                id: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Double(total),
                free: free,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? true
            )
        }
        .sorted { lhs, rhs in
            if lhs.path == "/" { return true }
            if rhs.path == "/" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Throughput

    /// Sums the byte counters every block storage driver publishes. These are
    /// cumulative since boot, so the rate comes from the delta between samples.
    private func blockStorageActivity() -> DiskActivity {
        var activity = DiskActivity()
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return activity }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return activity
        }
        defer { IOObjectRelease(iterator) }

        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        var readOps: UInt64 = 0
        var writeOps: UInt64 = 0

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                    entry, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue() as? [String: Any]
            else { continue }

            readBytes += (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? UInt64) ?? 0
            writeBytes += (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? UInt64) ?? 0
            readOps += (statistics[kIOBlockStorageDriverStatisticsReadsKey] as? UInt64) ?? 0
            writeOps += (statistics[kIOBlockStorageDriverStatisticsWritesKey] as? UInt64) ?? 0
        }

        activity.readTotal = Double(readBytes)
        activity.writeTotal = Double(writeBytes)
        activity.readOperations = readOps
        activity.writeOperations = writeOps

        let now = Date()
        if let lastRead = previousRead, let lastWrite = previousWrite, let last = previousTimestamp {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0 {
                activity.readRate = Double(readBytes &- lastRead).safeDivided(by: elapsed)
                activity.writeRate = Double(writeBytes &- lastWrite).safeDivided(by: elapsed)
            }
        }
        previousRead = readBytes
        previousWrite = writeBytes
        previousTimestamp = now
        return activity
    }
}
