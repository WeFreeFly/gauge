// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit
import IOKit.ps

public struct BatterySnapshot: Sendable {
    public var isPresent: Bool = false
    public var charge: Double = 0            // 0…1
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var isCharged: Bool = false
    public var timeToEmpty: TimeInterval?
    public var timeToFull: TimeInterval?
    public var cycleCount: Int?
    public var designCycleCount: Int?
    public var health: Double?               // current max ÷ design capacity
    public var condition: String?
    public var temperature: Double?          // °C
    public var voltage: Double?              // volts
    public var amperage: Double?             // amps, negative while discharging
    public var currentCapacity: Double?      // mAh
    public var maxCapacity: Double?          // mAh
    public var designCapacity: Double?       // mAh
    public var powerSource: String?
    public var adapterWatts: Double?
    /// Positive while discharging: how fast the pack is draining, in watts.
    public var drainWatts: Double?
    public var isOptimizedChargingPaused: Bool = false

    public var chargePercent: Int { Int((charge * 100).rounded()) }
}

public final class BatteryMonitor: @unchecked Sendable {
    private let smc = SMC.shared
    private var cached: BatterySnapshot?
    private var cachedAt: Date?

    /// Charge, health and temperature all move slowly.
    public var backgroundInterval: TimeInterval = 5

    public init() { smc.open() }

    /// Capacities below this are percentages the registry mislabels, not mAh.
    private static func capacityIfPlausible(_ value: Double) -> Double? {
        value > 100 ? value : nil
    }

    public func sample(live: Bool = true) -> BatterySnapshot {
        if !live, let cached, let cachedAt,
           Date().timeIntervalSince(cachedAt) < backgroundInterval {
            return cached
        }
        let snapshot = read()
        cached = snapshot
        cachedAt = Date()
        return snapshot
    }

    private func read() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        readPowerSources(into: &snapshot)
        readSmartBattery(into: &snapshot)
        readSMCDetails(into: &snapshot)
        return snapshot
    }

    // MARK: IOPowerSources

    private func readPowerSources(into snapshot: inout BatterySnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            snapshot.isPresent = true
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            snapshot.charge = maximum > 0 ? Double(current) / Double(maximum) : 0
            snapshot.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
            snapshot.powerSource = description[kIOPSPowerSourceStateKey] as? String
            snapshot.isPluggedIn = snapshot.powerSource == kIOPSACPowerValue

            // These come back as -1 when the estimate is not ready yet.
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                snapshot.timeToEmpty = TimeInterval(minutes * 60)
            }
            if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 {
                snapshot.timeToFull = TimeInterval(minutes * 60)
            }
            break
        }
    }

    // MARK: AppleSmartBattery registry

    private func readSmartBattery(into snapshot: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return }

        snapshot.isPresent = snapshot.isPresent || (properties["BatteryInstalled"] as? Bool ?? false)
        snapshot.cycleCount = properties["CycleCount"] as? Int
        snapshot.designCycleCount = properties["DesignCycleCount9C"] as? Int
        snapshot.condition = properties["BatteryHealthCondition"] as? String
            ?? (properties["PermanentFailureStatus"] as? Int == 0 ? "Normal" : nil)

        // On Apple Silicon this registry node reports CurrentCapacity and
        // MaxCapacity as percentages (both read 100 on a full battery), so a
        // value of 100 or less is not a milliamp-hour figure. Only the "raw"
        // keys — present on Intel — are real capacities; anything else is left
        // to the SMC pass below, which has the gas gauge's own numbers.
        let design = (properties["DesignCapacity"] as? Int).map(Double.init).flatMap(Self.capacityIfPlausible)
        let maximum = (properties["AppleRawMaxCapacity"] as? Int).map(Double.init).flatMap(Self.capacityIfPlausible)
        let current = (properties["AppleRawCurrentCapacity"] as? Int).map(Double.init).flatMap(Self.capacityIfPlausible)

        snapshot.designCapacity = design
        snapshot.maxCapacity = maximum
        snapshot.currentCapacity = current

        if let millivolts = properties["Voltage"] as? Int { snapshot.voltage = Double(millivolts) / 1000 }
        if let milliamps = properties["Amperage"] as? Int { snapshot.amperage = Double(milliamps) / 1000 }
        if let deciKelvin = properties["Temperature"] as? Int { snapshot.temperature = Double(deciKelvin) / 100 }

        // Set while the system deliberately holds the charge down for battery
        // longevity. A battery that has simply finished charging also reports a
        // non-zero reason, so exclude the full case.
        if let charging = properties["ChargerData"] as? [String: Any],
           let notCharging = charging["NotChargingReason"] as? Int {
            snapshot.isOptimizedChargingPaused = notCharging != 0
                && snapshot.isPluggedIn
                && !snapshot.isCharging
                && !snapshot.isCharged
                && snapshot.charge < 0.95
        }

        if let voltage = snapshot.voltage, let amperage = snapshot.amperage {
            let watts = voltage * amperage
            snapshot.drainWatts = watts < 0 ? -watts : nil
        }
    }

    // MARK: SMC extras

    /// Fills in whatever the registry did not provide. On Apple Silicon the
    /// SMC exposes the gas-gauge figures directly.
    private func readSMCDetails(into snapshot: inout BatterySnapshot) {
        if snapshot.currentCapacity == nil, let remaining = smc.double("B0RM"), remaining > 0 {
            snapshot.currentCapacity = remaining
        }
        if snapshot.maxCapacity == nil, let full = smc.double("B0FC"), full > 0 {
            snapshot.maxCapacity = full
        }
        if snapshot.designCapacity == nil, let design = smc.double("B0DC"), design > 0 {
            snapshot.designCapacity = design
        }
        if snapshot.temperature == nil, let centiDegrees = smc.double("B0AT"), centiDegrees > 0 {
            snapshot.temperature = centiDegrees / 100
        }
        // Health is only meaningful once both capacities are in the same unit.
        if snapshot.health == nil, let design = snapshot.designCapacity, let maximum = snapshot.maxCapacity,
           design > 0 {
            snapshot.health = (maximum / design).clamped(to: 0...1.2)
        }
        if snapshot.voltage == nil, let millivolts = smc.double("B0AV"), millivolts > 0 {
            snapshot.voltage = millivolts / 1000
        }
        if snapshot.amperage == nil, let milliamps = smc.double("B0AC") {
            snapshot.amperage = milliamps / 1000
        }
        if snapshot.cycleCount == nil, let cycles = smc.int("B0CT"), cycles > 0 {
            snapshot.cycleCount = cycles
        }
        if let adapter = smc.double("PDTR"), adapter > 0, adapter < 1000 {
            snapshot.adapterWatts = adapter
        }
        if !snapshot.isPresent, let charge = smc.double("BRSC"), charge > 0 {
            snapshot.isPresent = true
            snapshot.charge = (charge / 100).clamped(to: 0...1)
        }
    }
}
