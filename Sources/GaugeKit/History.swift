// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Ranges

/// How far back a chart looks.
public enum HistoryRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case m10, h1, h3, h6, h12, d1, d3, d7, d14, d28

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .m10: 10 * 60
        case .h1: 3600
        case .h3: 3 * 3600
        case .h6: 6 * 3600
        case .h12: 12 * 3600
        case .d1: 86400
        case .d3: 3 * 86400
        case .d7: 7 * 86400
        case .d14: 14 * 86400
        case .d28: 28 * 86400
        }
    }

    /// Long enough to be unambiguous in a menu.
    public var title: String {
        switch self {
        case .m10: "10 minutes"
        case .h1: "1 hour"
        case .h3: "3 hours"
        case .h6: "6 hours"
        case .h12: "12 hours"
        case .d1: "1 day"
        case .d3: "3 days"
        case .d7: "7 days"
        case .d14: "14 days"
        case .d28: "28 days"
        }
    }

    /// Short enough for a graph header.
    public var short: String {
        switch self {
        case .m10: "10m"
        case .h1: "1h"
        case .h3: "3h"
        case .h6: "6h"
        case .h12: "12h"
        case .d1: "1d"
        case .d3: "3d"
        case .d7: "7d"
        case .d14: "14d"
        case .d28: "28d"
        }
    }
}

// MARK: - Buckets

/// One slot of aggregated history. Keeping the extremes as well as the mean
/// matters: a one-second spike inside a fifteen-minute bucket would otherwise
/// vanish entirely at the longer ranges.
public struct HistoryBucket: Sendable, Equatable {
    public var minimum: Double
    public var average: Double
    public var maximum: Double
    public var count: Int

    public init(minimum: Double = 0, average: Double = 0, maximum: Double = 0, count: Int = 0) {
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func add(_ value: Double) {
        if count == 0 {
            minimum = value
            maximum = value
            average = value
            count = 1
            return
        }
        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
        average += (value - average) / Double(count + 1)
        count += 1
    }
}

/// A slice of history ready to plot.
public struct HistorySeries: Sendable {
    public var buckets: [HistoryBucket]
    /// Start of the first bucket.
    public var start: Date
    public var interval: TimeInterval

    public init(buckets: [HistoryBucket] = [], start: Date = .distantPast, interval: TimeInterval = 1) {
        self.buckets = buckets
        self.start = start
        self.interval = interval
    }

    public var averages: [Double] { buckets.map(\.average) }
    public var maxima: [Double] { buckets.map(\.maximum) }
    public var minima: [Double] { buckets.map(\.minimum) }
    public var isEmpty: Bool { buckets.isEmpty }

    /// The moment the bucket at `index` covers.
    public func date(at index: Int) -> Date {
        start.addingTimeInterval(interval * (Double(index) + 0.5))
    }

    public var peak: Double { buckets.map(\.maximum).max() ?? 0 }
    public var latest: Double { buckets.last?.average ?? 0 }
}

// MARK: - Tiers

/// A fixed-length ring of buckets at one resolution.
///
/// Three of these per metric cover ten minutes to twenty-eight days without
/// storing a month of two-second samples, which would be about a million
/// values per metric.
struct HistoryTier {
    let interval: TimeInterval
    let capacity: Int

    private(set) var buckets: [HistoryBucket]
    private(set) var head = 0
    private(set) var filled = 0
    /// Start of the bucket currently accumulating.
    private(set) var currentStart: Date = .distantPast
    private var current = HistoryBucket()

    init(interval: TimeInterval, capacity: Int) {
        self.interval = interval
        self.capacity = capacity
        self.buckets = Array(repeating: HistoryBucket(), count: capacity)
    }

    /// Bucket boundaries are aligned to the epoch so tiers line up across
    /// metrics and survive a restart without drifting.
    private func slotStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / interval).rounded(.down) * interval)
    }

    mutating func record(_ value: Double, at date: Date) {
        let slot = slotStart(for: date)
        if currentStart == .distantPast {
            currentStart = slot
        } else if slot < currentStart {
            // A sample older than the bucket being filled would silently
            // distort it. Sampling is always in order, so this only happens
            // if the clock steps backwards.
            return
        } else if slot > currentStart {
            closeCurrent()
            // Gaps — the machine was asleep, or the app was not running —
            // stay empty rather than being interpolated over.
            var missing = Int(slot.timeIntervalSince(currentStart) / interval) - 1
            missing = Swift.min(Swift.max(0, missing), capacity)
            for _ in 0..<missing { push(HistoryBucket()) }
            currentStart = slot
        }
        current.add(value)
    }

    private mutating func closeCurrent() {
        push(current)
        current = HistoryBucket()
    }

    private mutating func push(_ bucket: HistoryBucket) {
        buckets[head] = bucket
        head = (head + 1) % capacity
        filled = Swift.min(filled + 1, capacity)
    }

    /// Oldest first, including the bucket still filling.
    func ordered() -> (buckets: [HistoryBucket], start: Date) {
        guard filled > 0 || current.count > 0 else { return ([], .distantPast) }
        var result: [HistoryBucket] = []
        result.reserveCapacity(filled + 1)
        let first = (head - filled + capacity) % capacity
        for offset in 0..<filled { result.append(buckets[(first + offset) % capacity]) }
        if current.count > 0 { result.append(current) }

        let closedCount = result.count - (current.count > 0 ? 1 : 0)
        let start = currentStart.addingTimeInterval(-interval * Double(closedCount))
        return (result, start)
    }

    /// Everything from `date` onwards.
    func slice(since date: Date) -> HistorySeries {
        let (all, start) = ordered()
        guard !all.isEmpty else { return HistorySeries(interval: interval) }
        let skip = Swift.max(0, Int(date.timeIntervalSince(start) / interval))
        guard skip < all.count else { return HistorySeries(interval: interval) }
        return HistorySeries(buckets: Array(all[skip...]),
                             start: start.addingTimeInterval(interval * Double(skip)),
                             interval: interval)
    }

    // MARK: Serialisation

    func snapshot() -> TierSnapshot {
        let (all, start) = ordered()
        return TierSnapshot(interval: interval, start: start, buckets: all)
    }

    mutating func restore(_ snapshot: TierSnapshot) {
        guard snapshot.interval == interval, !snapshot.buckets.isEmpty else { return }
        let keep = Array(snapshot.buckets.suffix(capacity))
        buckets = Array(repeating: HistoryBucket(), count: capacity)
        head = 0
        filled = 0
        for bucket in keep { push(bucket) }
        currentStart = snapshot.start
            .addingTimeInterval(interval * Double(snapshot.buckets.count - keep.count + keep.count))
        current = HistoryBucket()
    }
}

struct TierSnapshot {
    var interval: TimeInterval
    var start: Date
    var buckets: [HistoryBucket]
}

// MARK: - Store

/// Every metric's history, at three resolutions, with the long tiers written
/// to disk so a range of days means something after a restart.
public final class HistoryStore: @unchecked Sendable {
    /// Two-second detail for the last hour, one-minute for a day, and a
    /// quarter-hour out to four weeks. Roughly 2.5 MB for twenty metrics.
    static let tierPlan: [(interval: TimeInterval, capacity: Int)] = [
        (2, 1_800),      // 1 hour
        (60, 1_500),     // ~25 hours
        (900, 2_700),    // ~28 days
    ]

    private var metrics: [String: [HistoryTier]] = [:]
    private let lock = NSLock()
    private var lastSave = Date.distantPast
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Gauge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.gauge")
        load()
    }

    // MARK: Recording

    public func record(_ metric: String, _ value: Double, at date: Date = Date()) {
        guard value.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if metrics[metric] == nil {
            metrics[metric] = Self.tierPlan.map { HistoryTier(interval: $0.interval, capacity: $0.capacity) }
        }
        for index in metrics[metric]!.indices {
            metrics[metric]![index].record(value, at: date)
        }
    }

    // MARK: Reading

    /// The best tier for a range: the finest one that still covers it, so a
    /// ten-minute chart is not drawn from quarter-hour averages.
    private func tierIndex(for range: HistoryRange) -> Int {
        for (index, tier) in Self.tierPlan.enumerated() {
            let span = tier.interval * Double(tier.capacity)
            if span >= range.seconds { return index }
        }
        return Self.tierPlan.count - 1
    }

    public func series(_ metric: String, range: HistoryRange, maximumPoints: Int = 400) -> HistorySeries {
        lock.lock()
        let tiers = metrics[metric]
        lock.unlock()
        guard let tiers else { return HistorySeries() }

        let index = tierIndex(for: range)
        let series = tiers[index].slice(since: Date().addingTimeInterval(-range.seconds))
        return Self.downsample(series, to: maximumPoints)
    }

    /// A chart a few hundred points wide cannot show 1,800 buckets, and
    /// drawing them all costs more than it shows.
    public static func downsample(_ series: HistorySeries, to maximumPoints: Int) -> HistorySeries {
        guard maximumPoints > 0, series.buckets.count > maximumPoints else { return series }
        let factor = Int((Double(series.buckets.count) / Double(maximumPoints)).rounded(.up))
        var merged: [HistoryBucket] = []
        merged.reserveCapacity(series.buckets.count / factor + 1)

        var index = 0
        while index < series.buckets.count {
            let slice = series.buckets[index..<min(index + factor, series.buckets.count)]
            let populated = slice.filter { !$0.isEmpty }
            if populated.isEmpty {
                merged.append(HistoryBucket())
            } else {
                let total = populated.reduce(0) { $0 + $1.average * Double($1.count) }
                let count = populated.reduce(0) { $0 + $1.count }
                merged.append(HistoryBucket(
                    minimum: populated.map(\.minimum).min() ?? 0,
                    average: count > 0 ? total / Double(count) : 0,
                    maximum: populated.map(\.maximum).max() ?? 0,
                    count: count))
            }
            index += factor
        }
        return HistorySeries(buckets: merged, start: series.start,
                             interval: series.interval * Double(factor))
    }

    /// Throws everything away. Used by the demo injection, which backdates its
    /// samples and would otherwise be rejected by the out-of-order guard.
    public func reset() {
        lock.lock()
        metrics.removeAll()
        lock.unlock()
    }

    public var metricNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return metrics.keys.sorted()
    }

    // MARK: Persistence

    /// Called on a timer and at quit. The live tier is left out: an hour of
    /// two-second detail is stale by the time the app comes back.
    public func saveIfNeeded(minimumInterval: TimeInterval = 60) {
        guard Date().timeIntervalSince(lastSave) >= minimumInterval else { return }
        save()
    }

    public func save() {
        lock.lock()
        let snapshots = metrics.mapValues { tiers in
            tiers.enumerated().filter { $0.offset > 0 }.map { $0.element.snapshot() }
        }
        lock.unlock()

        var data = Data()
        data.append(contentsOf: Array("GAUGEHS2".utf8))
        data.appendLittleEndian(UInt32(snapshots.count))
        for (name, tiers) in snapshots.sorted(by: { $0.key < $1.key }) {
            let nameBytes = Array(name.utf8)
            data.appendLittleEndian(UInt16(nameBytes.count))
            data.append(contentsOf: nameBytes)
            data.appendLittleEndian(UInt8(tiers.count))
            for tier in tiers {
                data.appendLittleEndian(tier.interval)
                data.appendLittleEndian(tier.start.timeIntervalSince1970)
                data.appendLittleEndian(UInt32(tier.buckets.count))
                for bucket in tier.buckets {
                    data.appendLittleEndian(bucket.minimum)
                    data.appendLittleEndian(bucket.average)
                    data.appendLittleEndian(bucket.maximum)
                    data.appendLittleEndian(UInt32(bucket.count))
                }
            }
        }

        // Atomic: a half-written history file would be worse than none.
        try? data.write(to: fileURL, options: .atomic)
        lastSave = Date()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), data.count > 12 else { return }
        var cursor = 0
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
            cursor += size
            return value
        }

        guard String(bytes: data[0..<8], encoding: .utf8) == "GAUGEHS2" else { return }
        cursor = 8
        guard let metricCount = read(UInt32.self) else { return }

        for _ in 0..<metricCount {
            guard let nameLength = read(UInt16.self),
                  cursor + Int(nameLength) <= data.count,
                  let name = String(bytes: data[cursor..<cursor + Int(nameLength)], encoding: .utf8)
            else { return }
            cursor += Int(nameLength)
            guard let tierCount = read(UInt8.self) else { return }

            var tiers = Self.tierPlan.map { HistoryTier(interval: $0.interval, capacity: $0.capacity) }
            for _ in 0..<tierCount {
                guard let interval = read(Double.self),
                      let start = read(Double.self),
                      let bucketCount = read(UInt32.self) else { return }
                var buckets: [HistoryBucket] = []
                buckets.reserveCapacity(Int(bucketCount))
                for _ in 0..<bucketCount {
                    guard let minimum = read(Double.self), let average = read(Double.self),
                          let maximum = read(Double.self), let count = read(UInt32.self) else { return }
                    buckets.append(HistoryBucket(minimum: minimum, average: average,
                                                 maximum: maximum, count: Int(count)))
                }
                if let index = tiers.firstIndex(where: { $0.interval == interval }) {
                    tiers[index].restore(TierSnapshot(interval: interval,
                                                      start: Date(timeIntervalSince1970: start),
                                                      buckets: buckets))
                }
            }
            metrics[name] = tiers
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T>(_ value: T) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
