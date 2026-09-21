import Foundation

/// A reading the Combined menu bar item can show.
///
/// Combined exists to replace several menu bar items with one, so it draws up
/// to four readings, two to a line. Anything beyond that stops being glanceable.
public enum CombinedMenubarItem: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpu
    case cpuPerformance
    case cpuEfficiency
    case loadAverage
    case memory
    case memoryUsed
    case swap
    case gpu
    case networkDown
    case networkUp
    case diskRead
    case diskWrite
    case diskFree
    case temperature
    case fan
    case power
    case battery
    case uptime

    public var id: String { rawValue }

    /// Four fits: two lines of two. A fifth would have nowhere to go.
    public static let maximumSelected = 4

    /// Reproduces what the item showed before it was configurable.
    public static let standard: [CombinedMenubarItem] = [.cpu, .memory, .networkDown, .networkUp]

    /// Groups rendered readings into menu bar lines. Two short values sit
    /// comfortably together; a third on the same line makes the item too wide
    /// to scan.
    public static func pack(_ values: [String], perLine: Int = 2) -> [String] {
        guard perLine > 0 else { return values }
        guard values.count > perLine else {
            return values.isEmpty ? [] : [values.joined(separator: "  ")]
        }
        return stride(from: 0, to: values.count, by: perLine).map { start in
            values[start..<Swift.min(start + perLine, values.count)].joined(separator: "  ")
        }
    }

    public func title(performanceCluster: String = "Performance",
                      efficiencyCluster: String = "Efficiency") -> String {
        switch self {
        case .cpu: "CPU usage"
        case .cpuPerformance: "\(performanceCluster) cores usage"
        case .cpuEfficiency: "\(efficiencyCluster) cores usage"
        case .loadAverage: "Load average"
        case .memory: "Memory used, as a share"
        case .memoryUsed: "Memory used, in bytes"
        case .swap: "Swap used"
        case .gpu: "GPU usage"
        case .networkDown: "Network download"
        case .networkUp: "Network upload"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .diskFree: "Boot volume free space"
        case .temperature: "CPU die temperature"
        case .fan: "Fan speed"
        case .power: "System power"
        case .battery: "Battery charge"
        case .uptime: "Uptime"
        }
    }

    /// For the summary line in the dropdown, where four full titles would not
    /// fit. The menu and the settings list keep the long names.
    public func shortTitle(performanceCluster: String = "Performance",
                           efficiencyCluster: String = "Efficiency") -> String {
        switch self {
        case .cpu: "CPU"
        case .cpuPerformance: String(performanceCluster.prefix(5))
        case .cpuEfficiency: String(efficiencyCluster.prefix(5))
        case .loadAverage: "Load"
        case .memory: "Memory %"
        case .memoryUsed: "Memory"
        case .swap: "Swap"
        case .gpu: "GPU"
        case .networkDown: "Net ↓"
        case .networkUp: "Net ↑"
        case .diskRead: "Disk R"
        case .diskWrite: "Disk W"
        case .diskFree: "Free"
        case .temperature: "CPU temp"
        case .fan: "Fan"
        case .power: "Power"
        case .battery: "Battery"
        case .uptime: "Uptime"
        }
    }

    /// Compact enough for a menu bar sharing a line with another reading.
    public func formatted(from snapshot: MonitorHub.Snapshot,
                          temperatureUnit: TemperatureUnit,
                          networkInBits: Bool) -> String? {
        func rate(_ value: Double) -> String {
            let scaled = networkInBits ? value * 8 : value
            let units = networkInBits ? ["b", "K", "M", "G"] : ["B", "K", "M", "G"]
            var amount = max(0, scaled)
            var unit = 0
            while amount >= 1024, unit < units.count - 1 {
                amount /= 1024
                unit += 1
            }
            return String(format: amount >= 10 || unit == 0 ? "%.0f%@" : "%.1f%@", amount, units[unit])
        }

        switch self {
        case .cpu: return Format.percent(snapshot.cpu.total)
        case .cpuPerformance: return "P" + Format.percent(snapshot.cpu.performanceLoad)
        case .cpuEfficiency: return "E" + Format.percent(snapshot.cpu.efficiencyLoad)
        case .loadAverage: return String(format: "%.1f", snapshot.cpu.loadAverage.one)
        case .memory: return Format.percent(snapshot.memory.usedFraction)
        case .memoryUsed: return Format.bytes(snapshot.memory.used, decimals: 1)
                                    .replacingOccurrences(of: " ", with: "")
        case .swap:
            guard snapshot.memory.swapUsed > 0 else { return "0" }
            return Format.bytes(snapshot.memory.swapUsed, decimals: 0)
                .replacingOccurrences(of: " ", with: "")
        case .gpu: return Format.percent(snapshot.gpu.utilization)
        case .networkDown: return "↓" + rate(snapshot.network.downloadRate)
        case .networkUp: return "↑" + rate(snapshot.network.uploadRate)
        case .diskRead: return "R" + rate(snapshot.disk.activity.readRate)
        case .diskWrite: return "W" + rate(snapshot.disk.activity.writeRate)
        case .diskFree:
            guard let volume = snapshot.disk.bootVolume else { return nil }
            return Format.bytes(volume.free, decimals: 0).replacingOccurrences(of: " ", with: "")
        case .temperature:
            guard let value = snapshot.sensors.socTemperature else { return nil }
            return Format.temperature(value, unit: temperatureUnit)
        case .fan:
            guard let fan = snapshot.sensors.fans.first else { return nil }
            return "\(Int(fan.rpm))"
        case .power:
            guard let value = snapshot.sensors.systemPower else { return nil }
            return String(format: value >= 10 ? "%.0fW" : "%.1fW", value)
        case .battery:
            guard snapshot.battery.isPresent else { return nil }
            return "\(snapshot.battery.chargePercent)%"
        case .uptime:
            guard snapshot.cpu.uptime > 0 else { return nil }
            return Format.duration(snapshot.cpu.uptime).replacingOccurrences(of: " ", with: "")
        }
    }

    /// Where the value sits on the load ramp, for colouring the first line.
    public func loadFraction(from snapshot: MonitorHub.Snapshot) -> Double? {
        switch self {
        case .cpu: snapshot.cpu.total
        case .cpuPerformance: snapshot.cpu.performanceLoad
        case .cpuEfficiency: snapshot.cpu.efficiencyLoad
        case .memory, .memoryUsed: snapshot.memory.pressureFraction
        case .gpu: snapshot.gpu.utilization
        case .temperature:
            snapshot.sensors.socTemperature.map { (($0 - 35) / 55).clamped(to: 0...1) }
        case .fan:
            snapshot.sensors.fans.first.map(\.loadFraction)
        case .battery:
            // Low charge is the alarming end, so the ramp runs the other way.
            snapshot.battery.isPresent ? 1 - snapshot.battery.charge : nil
        case .diskFree:
            snapshot.disk.bootVolume?.usedFraction
        case .loadAverage, .swap, .networkDown, .networkUp, .diskRead, .diskWrite, .power, .uptime:
            nil
        }
    }
}
