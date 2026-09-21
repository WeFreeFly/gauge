import SwiftUI
import GaugeKit

// MARK: - Network

struct NetworkPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let network = hub.snapshot.network
        let look = settings.graph(.network)
        Panel {
            PanelHeader(title: "Network",
                        subtitle: network.interfaces.first(where: \.isPrimary)?.displayName,
                        symbol: "network")

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Download", systemImage: "arrow.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(rate(network.downloadRate))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(look.primary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Label("Upload", systemImage: "arrow.up")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(rate(network.uploadRate))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(look.secondary)
                }
                Spacer()
            }

            VStack(spacing: 3) {
                Sparkline(values: hub.series.networkDown, secondary: hub.series.networkUp,
                          color: look.primary, secondaryColor: look.secondary,
                          height: 46, appearance: look)
                GraphCaption(trailing: "peak \(rate(max(network.peakDownload, network.peakUpload)))   ")
            }

            VStack(spacing: 4) {
                StatRow(label: "Peak down", value: rate(network.peakDownload))
                StatRow(label: "Peak up", value: rate(network.peakUpload))
                StatRow(label: "This session",
                        value: "↓ \(Format.bytes(network.sessionIn))  ↑ \(Format.bytes(network.sessionOut))")
                StatRow(label: "Since boot",
                        value: "↓ \(Format.bytes(network.totalIn))  ↑ \(Format.bytes(network.totalOut))")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Interfaces")
                ForEach(network.interfaces) { interface in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(interface.isPrimary ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5)
                            Text(interface.displayName)
                                .font(.system(size: 11, weight: .medium))
                            Text(interface.name)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        let addresses = interface.ipv4 + interface.ipv6
                        ForEach(addresses.prefix(4), id: \.self) { address in
                            Text(address)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if addresses.count > 4 {
                            Text("+\(addresses.count - 4) more addresses")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if settings.publicIPEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "Public address")
                    Text(network.publicIPv4 ?? "Looking up…")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if let v6 = network.publicIPv6, v6 != network.publicIPv4 {
                        Text(v6)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Text("Public address lookup is off. It is the only network request this module makes.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelFooter(
                onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .network) },
                extraLabel: "Reset session totals",
                extraAction: { hub.resetNetworkTotals() }
            )
        }
    }

    private func rate(_ value: Double) -> String {
        settings.networkUnitBits
            ? Format.rate(value * 8).replacingOccurrences(of: "B/s", with: "b/s")
            : Format.rate(value)
    }
}

// MARK: - Sensors

struct SensorsPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var expanded = UIState(false)

    var body: some View {
        let sensors = hub.snapshot.sensors
        let look = settings.graph(.sensors)
        Panel {
            PanelHeader(title: "Sensors",
                        subtitle: "\(sensors.readings.count) readings",
                        symbol: "thermometer.medium")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let soc = sensors.socTemperature {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU die avg").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(Format.temperature(soc, unit: settings.temperatureUnit, decimals: 1))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(look.valueColor(load: ((soc - 35) / 55).clamped(to: 0...1)))
                    }
                }
                if let peak = sensors.peakDieTemperature {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("peak").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(Format.temperature(peak, unit: settings.temperatureUnit, decimals: 1))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                    }
                }
                if let power = sensors.systemPower {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Power").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(Format.power(power))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                    }
                }
                Spacer()
            }

            if !hub.series.socTemperature.isEmpty {
                VStack(spacing: 3) {
                    Sparkline(values: hub.series.socTemperature, ceiling: 100, color: look.primary,
                              secondaryColor: look.secondary, height: 40, appearance: look)
                    GraphCaption(trailing: "0–100°C   ")
                }
            }

            if !sensors.fans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Fans")
                    ForEach(sensors.fans) { fan in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(fan.name).font(.system(size: 11))
                                Spacer()
                                Text("\(Int(fan.rpm)) rpm")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            BarMeter(fraction: fan.loadFraction, color: look.secondary)
                            Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM)) rpm")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                let groups = sensors.grouped.filter { $0.group != .fans }
                ForEach(groups.prefix(expanded.value ? 99 : 3), id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: entry.group.rawValue)
                        if expanded.value, let explanation = entry.group.explanation {
                            Text(explanation)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(expanded.value ? entry.readings : Array(entry.readings.prefix(4))) { reading in
                            StatRow(label: reading.name,
                                    value: reading.formatted(temperatureUnit: settings.temperatureUnit))
                        }
                        if !expanded.value, entry.readings.count > 4 {
                            Text("+\(entry.readings.count - 4) more")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Button(expanded.value ? "Show less" : "Show all sensors") { expanded.value.toggle() }
                .buttonStyle(.link)
                .font(.system(size: 10))

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .sensors) })
        }
    }
}

// MARK: - Battery

struct BatteryPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let battery = hub.snapshot.battery
        Panel {
            PanelHeader(title: "Battery", subtitle: statusLine(battery), symbol: "battery.75percent")

            if battery.isPresent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(battery.chargePercent)%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(chargeColor(battery))
                    Spacer()
                    if let time = battery.isCharging ? battery.timeToFull : battery.timeToEmpty {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(battery.isCharging ? "until full" : "remaining")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(Format.duration(time))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                    }
                }

                BarMeter(fraction: battery.charge, color: chargeColor(battery), height: 7)

                if battery.isOptimizedChargingPaused {
                    Text("Charging is paused by battery health management.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 4) {
                    if let health = battery.health {
                        StatRow(label: "Health", value: Format.percent(health, decimals: 1),
                                valueColor: health < 0.8 ? .orange : .primary)
                    }
                    if let cycles = battery.cycleCount {
                        let designCycles = battery.designCycleCount
                        StatRow(label: "Cycles",
                                value: designCycles.map { "\(cycles) of \($0)" } ?? "\(cycles)")
                    }
                    if let condition = battery.condition {
                        StatRow(label: "Condition", value: condition, monospaced: false)
                    }
                    if let current = battery.currentCapacity, let maximum = battery.maxCapacity {
                        StatRow(label: "Capacity", value: "\(Int(current)) / \(Int(maximum)) mAh")
                    }
                    if let design = battery.designCapacity {
                        StatRow(label: "Design capacity", value: "\(Int(design)) mAh")
                    }
                    if let voltage = battery.voltage {
                        StatRow(label: "Voltage", value: String(format: "%.2f V", voltage))
                    }
                    if let amperage = battery.amperage, amperage != 0 {
                        StatRow(label: "Current", value: String(format: "%.2f A", amperage))
                    }
                    if let temperature = battery.temperature {
                        StatRow(label: "Temperature",
                                value: Format.temperature(temperature, unit: settings.temperatureUnit, decimals: 1))
                    }
                    if let adapter = battery.adapterWatts {
                        StatRow(label: "Adapter", value: Format.power(adapter))
                    }
                    if let drain = battery.drainWatts {
                        StatRow(label: "Drain", value: Format.power(drain), valueColor: .orange)
                    }
                }
            } else {
                Text("This Mac has no battery.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .battery) })
        }
    }

    private func statusLine(_ battery: BatterySnapshot) -> String? {
        guard battery.isPresent else { return nil }
        if battery.isCharging { return "Charging" }
        if battery.isCharged && battery.isPluggedIn { return "Charged · on power adapter" }
        if battery.isPluggedIn { return "On power adapter" }
        return "On battery"
    }

    private func chargeColor(_ battery: BatterySnapshot) -> Color {
        if battery.isCharging { return .green }
        return switch battery.charge {
        case ..<0.1: .red
        case ..<0.2: .orange
        default: .primary
        }
    }
}

// MARK: - Time

struct TimePanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var clock = UIState(Date())

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Panel(width: 280) {
            PanelHeader(title: "Time", subtitle: TimeZone.current.identifier, symbol: "clock")

            Text(clock.value, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(localTime(clock.value, zone: .current))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if settings.timeZones.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "World clocks")
                    ForEach(settings.timeZones.filter { $0 != TimeZone.current.identifier }, id: \.self) { identifier in
                        if let zone = TimeZone(identifier: identifier) {
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(zone.identifier.split(separator: "/").last.map(String.init)?
                                        .replacingOccurrences(of: "_", with: " ") ?? identifier)
                                        .font(.system(size: 11))
                                    Text(offsetLabel(zone))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(localTime(clock.value, zone: zone))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                            }
                        }
                    }
                }
            }

            StatRow(label: "Uptime", value: Format.duration(hub.snapshot.cpu.uptime))

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .time) })
        }
        .onReceive(tick) { clock.value = $0 }
    }

    private func localTime(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = settings.timeFormat.contains("s") ? settings.timeFormat : settings.timeFormat + ":ss"
        return formatter.string(from: date)
    }

    private func offsetLabel(_ zone: TimeZone) -> String {
        let difference = (zone.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600
        if difference == 0 { return "same time" }
        return difference > 0 ? "+\(difference)h" : "\(difference)h"
    }
}

// MARK: - Combined

struct CombinedPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let snapshot = hub.snapshot
        Panel(width: 320) {
            PanelHeader(title: hub.hardware.modelIdentifier,
                        subtitle: "\(hub.hardware.chip) · macOS \(hub.hardware.osVersion)",
                        symbol: "square.grid.2x2")

            HStack(spacing: 10) {
                summaryTile("CPU", Format.percent(snapshot.cpu.total),
                            settings.graph(.cpu), snapshot.cpu.total, hub.series.cpu)
                summaryTile("Memory", Format.percent(snapshot.memory.usedFraction),
                            settings.graph(.memory), snapshot.memory.pressureFraction, hub.series.memory)
                summaryTile("GPU", Format.percent(snapshot.gpu.utilization),
                            settings.graph(.gpu), snapshot.gpu.utilization, hub.series.gpu)
            }

            VStack(spacing: 4) {
                StatRow(label: "Network",
                        value: "↓ \(Format.rate(snapshot.network.downloadRate))  ↑ \(Format.rate(snapshot.network.uploadRate))")
                StatRow(label: "Disk",
                        value: "R \(Format.rate(snapshot.disk.activity.readRate))  W \(Format.rate(snapshot.disk.activity.writeRate))")
                if let volume = snapshot.disk.bootVolume {
                    StatRow(label: volume.name, value: "\(Format.bytes(volume.free)) free")
                }
                if let temperature = snapshot.sensors.socTemperature {
                    StatRow(label: "SoC temperature",
                            value: Format.temperature(temperature, unit: settings.temperatureUnit, decimals: 1))
                }
                if let fan = snapshot.sensors.fans.first {
                    StatRow(label: fan.name, value: "\(Int(fan.rpm)) rpm")
                }
                if let power = snapshot.sensors.systemPower {
                    StatRow(label: "System power", value: Format.power(power))
                }
                if snapshot.battery.isPresent {
                    StatRow(label: "Battery",
                            value: "\(snapshot.battery.chargePercent)%" +
                                   (snapshot.battery.isCharging ? " charging" : ""))
                }
                StatRow(label: "Uptime", value: Format.duration(snapshot.cpu.uptime))
            }

            Divider()
            ProcessList(title: "Top by CPU", processes: Array(snapshot.topByCPU.prefix(5)), showsMemory: false)

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: nil) })
        }
    }

    private func summaryTile(_ title: String, _ value: String, _ look: GraphAppearance,
                             _ load: Double, _ series: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(look.valueColor(load: load))
            Sparkline(values: series, ceiling: 1, color: look.primary,
                      secondaryColor: look.secondary, height: 22,
                      showsBaseline: false, appearance: look)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
