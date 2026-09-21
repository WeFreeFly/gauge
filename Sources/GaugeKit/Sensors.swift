import Foundation

// MARK: - Model

public enum SensorKind: String, Codable, Sendable, CaseIterable {
    case temperature, fan, power, voltage, current
}

public enum SensorGroup: String, Codable, Sendable, CaseIterable {
    case cpu = "CPU Die"
    case package = "Package"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case board = "Board"
    case power = "Power"
    case fans = "Fans"
    case other = "Other"

    public var sortOrder: Int {
        switch self {
        case .cpu: 0; case .memory: 1; case .storage: 2; case .battery: 3
        case .power: 4; case .fans: 5; case .package: 6; case .board: 7; case .other: 8
        }
    }

    /// Shown under the group heading, so the reader knows what the numbers are
    /// and — just as importantly — what they are not.
    public var explanation: String? {
        switch self {
        case .cpu:
            "Thermal sensors spread across the compute die. They all track CPU load; Apple does not publish which one sits over which core."
        case .package:
            "Elsewhere in the package. These barely move under CPU load."
        case .board:
            "Board and power-delivery sensors around the chip."
        default:
            nil
        }
    }
}

public struct SensorReading: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let group: SensorGroup
    public let kind: SensorKind
    public let value: Double
    /// Populated for fans, which have a known operating envelope.
    public let range: ClosedRange<Double>?
    /// Display order within a group. Lower comes first; ties fall back to a
    /// numeric-aware name comparison so "Die 10" lands after "Die 2".
    public let order: Int

    public init(id: String, name: String, group: SensorGroup, kind: SensorKind,
                value: Double, range: ClosedRange<Double>? = nil, order: Int = 0) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
        self.value = value
        self.range = range
        self.order = order
    }

    public func formatted(temperatureUnit: TemperatureUnit) -> String {
        switch kind {
        case .temperature: Format.temperature(value, unit: temperatureUnit)
        case .fan:         "\(Int(value.rounded())) rpm"
        case .power:       Format.power(value)
        case .voltage:     String(format: "%.2f V", value)
        case .current:     String(format: "%.2f A", value)
        }
    }
}

public struct FanReading: Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let rpm: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?

    public init(id: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double, targetRPM: Double?) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }

    /// 0…1 position within the fan's own operating range, for gauges.
    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((rpm - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

public struct SensorSnapshot: Sendable {
    public var readings: [SensorReading] = []
    public var fans: [FanReading] = []
    /// Average of the compute-die sensors — the number most people mean by
    /// "CPU temperature".
    public var socTemperature: Double?
    /// The hottest single die sensor. Throttling follows the peak, not the mean.
    public var peakDieTemperature: Double?
    public var storageTemperature: Double?
    public var batteryTemperature: Double?
    /// Total system power draw in watts, from the SMC's own rail accounting.
    public var systemPower: Double?
    public var adapterPower: Double?

    public init() {}

    public var grouped: [(group: SensorGroup, readings: [SensorReading])] {
        Dictionary(grouping: readings, by: \.group)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { entry in
                (group: entry.key, readings: entry.value.sorted { lhs, rhs in
                    lhs.order == rhs.order
                        ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                        : lhs.order < rhs.order
                })
            }
    }
}

// MARK: - IOHID temperature sensors (Apple Silicon)

/// Reads the HID temperature sensors Apple Silicon exposes on usage page 0xff00.
///
/// These entry points are not in any public header, so they are resolved by
/// name at run time. Every call site tolerates them being absent, which is what
/// happens on Intel (there the SMC path below supplies temperatures instead).
final class HIDSensorReader {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ClientSetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias ClientCopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<AnyObject>?
    private typealias ServiceCopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventGetFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    private static let temperatureEventType: Int64 = 15   // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)
    private static let usagePage = 0xff00
    private static let temperatureUsage = 5

    private let copyProperty: ServiceCopyProperty
    private let copyEvent: ServiceCopyEvent
    private let floatValue: EventGetFloatValue
    private let client: AnyObject
    /// Names never change for the life of a service, and asking for one costs
    /// as much as reading a temperature, so they are resolved once.
    private var sensors: [(name: String, service: AnyObject)] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        let create = unsafeBitCast(createSym, to: ClientCreate.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
        self.copyProperty = unsafeBitCast(propertySym, to: ServiceCopyProperty.self)
        self.copyEvent = unsafeBitCast(eventSym, to: ServiceCopyEvent.self)
        self.floatValue = unsafeBitCast(floatSym, to: EventGetFloatValue.self)

        let setMatching = unsafeBitCast(matchSym, to: ClientSetMatching.self)
        setMatching(client, ["PrimaryUsagePage": Self.usagePage,
                             "PrimaryUsage": Self.temperatureUsage] as CFDictionary)

        let copyServices = unsafeBitCast(servicesSym, to: ClientCopyServices.self)
        guard let list = copyServices(client)?.takeRetainedValue() as? [AnyObject], !list.isEmpty else { return nil }

        let nameOf = unsafeBitCast(propertySym, to: ServiceCopyProperty.self)
        self.sensors = list.compactMap { service in
            guard let name = nameOf(service, "Product" as CFString)?.takeRetainedValue() as? String
            else { return nil }
            return (name, service)
        }
        if sensors.isEmpty { return nil }
    }

    /// Sensor name → °C, with implausible readings dropped. Some sensors on an
    /// idle machine report values like -9201, which are placeholders rather
    /// than measurements.
    /// Reading one sensor costs about a millisecond, so which ones are read
    /// matters more than anything else in the sampling loop.
    func read(where include: ((String) -> Bool)? = nil) -> [(name: String, celsius: Double)] {
        var result: [(String, Double)] = []
        result.reserveCapacity(sensors.count)
        for sensor in sensors {
            if let include, !include(sensor.name) { continue }
            guard let event = copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = floatValue(event, Self.temperatureField)
            guard value.isFinite, value > -40, value < 150 else { continue }
            result.append((sensor.name, value))
        }
        return result
    }

    func readAll() -> [(name: String, celsius: Double)] { read() }
}

// MARK: - Monitor

public final class SensorMonitor: @unchecked Sendable {
    private let hid = HIDSensorReader()
    private let smc = SMC.shared
    private var fanCount: Int?
    private var cached: SensorSnapshot?
    private var cachedAt: Date?

    /// Reading every sensor is the single most expensive thing the app does.
    /// Temperatures move slowly, so a background pass every few seconds is
    /// indistinguishable from one per tick; a visible panel gets live data.
    public var backgroundInterval: TimeInterval = 4

    public init() { smc.open() }

    public var hasHIDSensors: Bool { hid != nil }

    public func sample(live: Bool = true) -> SensorSnapshot {
        if !live, let cachedAt, Date().timeIntervalSince(cachedAt) < backgroundInterval,
           let cached {
            return cached
        }
        // A menu bar item needs the SoC average, the fans and the power draw.
        // The full list only appears in a panel, and opening one switches this
        // to the live path, so the background pass skips the other two thirds
        // of the sensors and keeps the previous values for them.
        let snapshot = read(essentialOnly: !live)
        cached = snapshot
        cachedAt = Date()
        return snapshot
    }

    private func read(essentialOnly: Bool) -> SensorSnapshot {
        var snapshot = SensorSnapshot()
        var socDieTemps: [Double] = []
        var batteryTemps: [Double] = []

        let readings = essentialOnly
            ? (hid?.read { $0.contains("tdie") } ?? [])
            : (hid?.readAll() ?? [])

        for (name, celsius) in readings {
            // A calibration reference, not a measurement of anything.
            if name.hasSuffix("tcal") { continue }

            let group = Self.group(forSensorNamed: name)
            let display = Self.displayName(forSensorNamed: name)
            snapshot.readings.append(SensorReading(id: "hid.\(name)", name: display,
                                                   group: group, kind: .temperature, value: celsius,
                                                   order: Self.order(forSensorNamed: name)))

            if group == .cpu { socDieTemps.append(celsius) }
            if group == .battery { batteryTemps.append(celsius) }
            if group == .storage { snapshot.storageTemperature = max(snapshot.storageTemperature ?? 0, celsius) }
        }

        if !socDieTemps.isEmpty {
            snapshot.socTemperature = socDieTemps.reduce(0, +) / Double(socDieTemps.count)
            snapshot.peakDieTemperature = socDieTemps.max()
        }
        if !batteryTemps.isEmpty {
            snapshot.batteryTemperature = batteryTemps.reduce(0, +) / Double(batteryTemps.count)
        }

        readIntelTemperaturesIfNeeded(into: &snapshot, socDieTemps: socDieTemps)
        readFans(into: &snapshot)
        readPower(into: &snapshot)

        if essentialOnly, let previous = cached {
            // Keep the sensors this pass did not read, so a panel opened a
            // moment later is never half empty.
            let refreshed = Set(snapshot.readings.map(\.id))
            snapshot.readings.append(contentsOf: previous.readings.filter { !refreshed.contains($0.id) })
            snapshot.storageTemperature = snapshot.storageTemperature ?? previous.storageTemperature
            snapshot.batteryTemperature = snapshot.batteryTemperature ?? previous.batteryTemperature
        }
        return snapshot
    }

    // MARK: Fans

    private func readFans(into snapshot: inout SensorSnapshot) {
        if fanCount == nil { fanCount = smc.int("FNum") ?? 0 }
        guard let count = fanCount, count > 0 else { return }

        for index in 0..<count {
            guard let rpm = smc.double("F\(index)Ac") else { continue }
            let minRPM = smc.double("F\(index)Mn") ?? 0
            let maxRPM = smc.double("F\(index)Mx") ?? 0
            let target = smc.double("F\(index)Tg")
            let name = count == 1 ? "Fan" : "Fan \(index + 1)"

            snapshot.fans.append(FanReading(id: index, name: name, rpm: rpm,
                                            minRPM: minRPM, maxRPM: maxRPM, targetRPM: target))
            snapshot.readings.append(SensorReading(id: "fan.\(index)", name: name, group: .fans,
                                                   kind: .fan, value: rpm,
                                                   range: maxRPM > minRPM ? minRPM...maxRPM : nil))
        }
    }

    // MARK: Power rails

    private func readPower(into snapshot: inout SensorSnapshot) {
        // PSTR: total system draw. PDTR: what the charger is delivering.
        if let systemPower = smc.double("PSTR"), systemPower > 0, systemPower < 1000 {
            snapshot.systemPower = systemPower
            snapshot.readings.append(SensorReading(id: "pwr.system", name: "System Total",
                                                   group: .power, kind: .power, value: systemPower))
        }
        // An unplugged machine still reports a fraction of a watt on this
        // rail, which reads as a charger that is not there.
        if let adapter = smc.double("PDTR"), adapter > 1, adapter < 1000 {
            snapshot.adapterPower = adapter
            snapshot.readings.append(SensorReading(id: "pwr.adapter", name: "Power Adapter",
                                                   group: .power, kind: .power, value: adapter))
        }
        if let rail = smc.double("PMVR"), rail > 0, rail < 1000 {
            snapshot.readings.append(SensorReading(id: "pwr.rail", name: "Main Rail",
                                                   group: .power, kind: .power, value: rail))
        }
    }

    // MARK: Intel fallback

    /// On Intel the HID sensor tree is empty, so fall back to the classic SMC
    /// temperature keys. Harmless on Apple Silicon: the keys simply do not exist.
    private func readIntelTemperaturesIfNeeded(into snapshot: inout SensorSnapshot, socDieTemps: [Double]) {
        guard socDieTemps.isEmpty else { return }

        let intelKeys: [(key: String, name: String, group: SensorGroup)] = [
            ("TC0P", "CPU Proximity", .cpu),
            ("TC0D", "CPU Die", .cpu),
            ("TCXC", "CPU Core", .cpu),
            ("TG0P", "GPU Proximity", .package),
            ("TG0D", "GPU Die", .package),
            ("TM0P", "Memory Proximity", .memory),
            ("TA0P", "Ambient", .board),
            ("Ts0P", "Palm Rest", .board),
            ("TB0T", "Battery", .battery),
        ]

        var cpuTemps: [Double] = []
        for entry in intelKeys {
            guard let value = smc.double(entry.key), value > 0, value < 150 else { continue }
            snapshot.readings.append(SensorReading(id: "smc.\(entry.key)", name: entry.name,
                                                   group: entry.group, kind: .temperature, value: value))
            if entry.key.hasPrefix("TC") { cpuTemps.append(value) }
            if entry.group == .battery { snapshot.batteryTemperature = value }
        }
        if !cpuTemps.isEmpty {
            snapshot.socTemperature = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
            snapshot.peakDieTemperature = cpuTemps.max()
        }
    }

    // MARK: Naming

    /// Apple Silicon sensor names are terse ("PMU tdie5"). Map them onto
    /// something a person can act on.
    ///
    /// The split is measured, not guessed: loading one core cluster at a time
    /// and watching which sensors respond shows the `PMU tdie*` set tracking
    /// CPU load closely (+7 to +19 °C under load on a Mac17,2) while
    /// `PMU2 tdie*` barely moves (+0.2 to +1.3 °C). Only the first set belongs
    /// in a CPU temperature. `Gauge --map-sensors` reproduces the measurement.
    public static func group(forSensorNamed name: String) -> SensorGroup {
        let lower = name.lowercased()
        if lower.contains("battery") || lower.contains("gas gauge") { return .battery }
        if lower.contains("nand") || lower.contains("ssd") { return .storage }
        if lower.contains("dram") || lower.contains("memory") { return .memory }

        let isSecondary = lower.contains("pmu2")
        if lower.contains("tdie") { return isSecondary ? .package : .cpu }
        if lower.contains("tdev") { return .board }
        if lower.contains("pmu") { return .board }
        return .other
    }

    /// The primary die is the one people mean by "the chip"; anything on the
    /// second die, and the board sensors, sit below it.
    public static func order(forSensorNamed name: String) -> Int {
        let lower = name.lowercased()
        var order = 0
        if lower.contains("pmu2") { order += 100 }
        if lower.contains("tdev") { order += 10 }
        return order
    }

    public static func displayName(forSensorNamed name: String) -> String {
        if name.lowercased().contains("gas gauge") { return "Battery Cell" }
        if name.hasPrefix("NAND") { return name.replacingOccurrences(of: "NAND", with: "SSD") }

        // "PMU tdie5" → "CPU Die 5", "PMU2 tdie3" → "Package Die 3",
        // "PMU tdev1" → "Board Sensor 1".
        var result = name
        for (raw, readable) in [("PMU2 tdie", "Package Die "), ("PMU tdie", "CPU Die "),
                                ("PMU2 tdev", "Board 2 Sensor "), ("PMU tdev", "Board Sensor "),
                                ("PMU2", "Package"), ("PMU", "SoC")] {
            result = result.replacingOccurrences(of: raw, with: readable)
        }
        return result
    }
}
