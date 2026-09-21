// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A reading the Sensors menu bar item can show.
///
/// The menu bar has room for one line at normal size or two at a smaller one,
/// so the choice matters: what is worth a permanent place on screen differs
/// between a laptop watching its fan and a machine watching its SSD.
public enum SensorMenubarItem: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpuDieAverage
    case cpuDieHottest
    case performanceCluster
    case efficiencyCluster
    case fanSpeed
    case fanPercent
    case systemPower
    case adapterPower
    case ssdTemperature
    case batteryTemperature

    public var id: String { rawValue }

    /// How many can be shown at once before the item stops being readable.
    public static let maximumSelected = 2

    public static let standard: [SensorMenubarItem] = [.cpuDieAverage, .fanSpeed]

    public func title(performanceCluster: String = "Performance",
                      efficiencyCluster: String = "Efficiency") -> String {
        switch self {
        case .cpuDieAverage: "CPU die average"
        case .cpuDieHottest: "Hottest CPU die sensor"
        case .performanceCluster: "\(performanceCluster) cores temperature"
        case .efficiencyCluster: "\(efficiencyCluster) cores temperature"
        case .fanSpeed: "Fan speed"
        case .fanPercent: "Fan, as a share of its range"
        case .systemPower: "System power"
        case .adapterPower: "Power adapter"
        case .ssdTemperature: "SSD temperature"
        case .batteryTemperature: "Battery temperature"
        }
    }

    /// For the summary line in the dropdown; the menu keeps the long names.
    public func shortTitle(performanceCluster: String = "Performance",
                           efficiencyCluster: String = "Efficiency") -> String {
        switch self {
        case .cpuDieAverage: "CPU die"
        case .cpuDieHottest: "Hottest die"
        case .performanceCluster: String(performanceCluster.prefix(5))
        case .efficiencyCluster: String(efficiencyCluster.prefix(5))
        case .fanSpeed: "Fan"
        case .fanPercent: "Fan %"
        case .systemPower: "Power"
        case .adapterPower: "Adapter"
        case .ssdTemperature: "SSD"
        case .batteryTemperature: "Battery"
        }
    }

    /// Needs a calibration before it can be offered.
    public var requiresCalibration: Bool {
        self == .performanceCluster || self == .efficiencyCluster
    }

    /// The reading itself, or nil when this Mac does not report it.
    public func value(from sensors: SensorSnapshot, unit: TemperatureUnit) -> Double? {
        switch self {
        case .cpuDieAverage: sensors.socTemperature
        case .cpuDieHottest: sensors.peakDieTemperature
        case .performanceCluster: sensors.performanceClusterTemperature
        case .efficiencyCluster: sensors.efficiencyClusterTemperature
        case .fanSpeed: sensors.fans.first.map(\.rpm)
        case .fanPercent: sensors.fans.first.map { $0.loadFraction * 100 }
        case .systemPower: sensors.systemPower
        case .adapterPower: sensors.adapterPower
        case .ssdTemperature: sensors.storageTemperature
        case .batteryTemperature: sensors.batteryTemperature
        }
    }

    /// Short enough for the menu bar: no space before the unit, no decimals
    /// where they would not survive the width.
    public func formatted(from sensors: SensorSnapshot, unit: TemperatureUnit) -> String? {
        guard let value = value(from: sensors, unit: unit) else { return nil }
        switch self {
        case .cpuDieAverage, .cpuDieHottest, .performanceCluster, .efficiencyCluster,
             .ssdTemperature, .batteryTemperature:
            return Format.temperature(value, unit: unit)
        case .fanSpeed:
            return "\(Int(value.rounded())) rpm"
        case .fanPercent:
            return "\(Int(value.rounded()))%"
        case .systemPower, .adapterPower:
            return String(format: value >= 10 ? "%.0fW" : "%.1fW", value)
        }
    }

    /// A one-letter prefix so two stacked lines can be told apart.
    public var shortPrefix: String {
        switch self {
        case .cpuDieAverage, .cpuDieHottest: ""
        case .performanceCluster: "P "
        case .efficiencyCluster: "E "
        case .fanSpeed, .fanPercent: ""
        case .systemPower: ""
        case .adapterPower: "AC "
        case .ssdTemperature: "SSD "
        case .batteryTemperature: "BAT "
        }
    }

    /// Where the value sits on the load ramp, for colouring. Nil leaves it in
    /// the menu bar's own colour.
    public func loadFraction(from sensors: SensorSnapshot) -> Double? {
        switch self {
        case .cpuDieAverage, .cpuDieHottest, .performanceCluster, .efficiencyCluster:
            guard let value = value(from: sensors, unit: .celsius) else { return nil }
            return ((value - 35) / 55).clamped(to: 0...1)
        case .ssdTemperature:
            guard let value = value(from: sensors, unit: .celsius) else { return nil }
            return ((value - 30) / 45).clamped(to: 0...1)
        case .batteryTemperature:
            guard let value = value(from: sensors, unit: .celsius) else { return nil }
            return ((value - 25) / 20).clamped(to: 0...1)
        case .fanPercent:
            guard let value = value(from: sensors, unit: .celsius) else { return nil }
            return (value / 100).clamped(to: 0...1)
        case .fanSpeed, .systemPower, .adapterPower:
            return nil
        }
    }
}
