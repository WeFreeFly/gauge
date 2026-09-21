// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - History

/// Fixed-capacity ring buffer used for every sparkline in the app. Sampling runs
/// on a timer forever, so the buffers must not grow.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Oldest value first — the order a left-to-right chart wants.
    public var values: [Element] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }

    public var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head - 1 + capacity) % capacity]
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}

// MARK: - Formatting

public enum Format {
    /// Base-2 byte sizes (what Activity Monitor calls GB).
    public static func bytes(_ value: Double, decimals: Int? = nil) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = abs(value)
        var unit = 0
        while v >= 1024, unit < units.count - 1 {
            v /= 1024
            unit += 1
        }
        let places = decimals ?? (v >= 100 || unit == 0 ? 0 : (v >= 10 ? 1 : 2))
        return String(format: "%.\(places)f %@", value < 0 ? -v : v, units[unit])
    }

    /// Per-second throughput, rendered compactly enough for a menu bar.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "K/s", "M/s", "G/s"]
        var v = max(0, bytesPerSecond)
        var unit = 0
        while v >= 1024, unit < units.count - 1 {
            v /= 1024
            unit += 1
        }
        let places = v >= 100 || unit == 0 ? 0 : (v >= 10 ? 1 : 1)
        return String(format: "%.\(places)f %@", v, units[unit])
    }

    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", (fraction * 100).clamped(to: 0...100))
    }

    public static func temperature(_ celsius: Double, unit: TemperatureUnit, decimals: Int = 0) -> String {
        switch unit {
        case .celsius:    return String(format: "%.\(decimals)f°C", celsius)
        case .fahrenheit: return String(format: "%.\(decimals)f°F", celsius * 9 / 5 + 32)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    public static func power(_ watts: Double) -> String {
        String(format: watts >= 10 ? "%.1f W" : "%.2f W", watts)
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit
    public var symbol: String { self == .celsius ? "°C" : "°F" }
}

// MARK: - Small numeric helpers

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public extension Double {
    /// Guards the many rate calculations that divide by an elapsed interval.
    func safeDivided(by divisor: Double) -> Double {
        divisor.magnitude < .ulpOfOne ? 0 : self / divisor
    }
}
