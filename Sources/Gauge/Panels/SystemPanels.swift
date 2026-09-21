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

            HStack(spacing: 0) {
                readout("Download", rate(network.downloadRate), "arrow.down", look.primary)
                readout("Upload", rate(network.uploadRate), "arrow.up", look.secondary)
            }

            MetricChart(
                chart: "network.bandwidth",
                title: "Bandwidth",
                sources: [.init(metric: MonitorHub.Metric.networkDown, color: look.primary,
                                label: "Down", format: { rate($0) }),
                          .init(metric: MonitorHub.Metric.networkUp, color: look.secondary,
                                label: "Up", format: { rate($0) })],
                shape: look.shape,
                autoScale: true,
                height: 62,
                appearance: look,
                value: "↓ \(rate(network.downloadRate))  ↑ \(rate(network.uploadRate))"
            )

            Divider()

            VStack(spacing: 2) {
                StatRow(label: "Peak down", value: rate(network.peakDownload), valueColor: look.primary)
                StatRow(label: "Peak up", value: rate(network.peakUpload), valueColor: look.secondary)
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

    private func readout(_ title: String, _ value: String,
                         _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        let sensors = hub.snapshot.sensors
        let look = settings.graph(.sensors)

        Panel {
            PanelHeader(title: "Sensors",
                        subtitle: "\(sensors.readings.count) readings",
                        symbol: "thermometer.medium")

            HStack(alignment: .center, spacing: 14) {
                if let soc = sensors.socTemperature {
                    RingGauge(fraction: ((soc - 30) / 70).clamped(to: 0...1),
                              color: look.valueColor(load: ((soc - 35) / 55).clamped(to: 0...1)),
                              label: Format.temperature(soc, unit: settings.temperatureUnit),
                              caption: "CPU die")
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let peak = sensors.peakDieTemperature {
                        StatRow(label: "Hottest die sensor",
                                value: Format.temperature(peak, unit: settings.temperatureUnit, decimals: 1))
                    }
                    if let power = sensors.systemPower {
                        StatRow(label: "System power", value: Format.power(power))
                    }
                    if let adapter = sensors.adapterPower {
                        StatRow(label: "Adapter", value: Format.power(adapter))
                    }
                }
            }

            ClockSection()

            SensorMenubarPicker(style: .compact)

            MetricChart(
                chart: "sensors.temperature",
                title: "CPU die temperature",
                sources: [.init(metric: MonitorHub.Metric.temperature, color: look.primary,
                                label: "CPU die",
                                format: { Format.temperature($0, unit: settings.temperatureUnit,
                                                             decimals: 1) })],
                shape: look.shape == .stacked || look.shape == .mirrored ? .area : look.shape,
                ceiling: 100,
                height: 46,
                appearance: look,
                value: sensors.socTemperature.map {
                    Format.temperature($0, unit: settings.temperatureUnit, decimals: 1)
                },
                caption: "0–100 °C"
            )
            HeatStrip(values: hub.series(MonitorHub.Metric.temperature,
                                         range: settings.chartRange("sensors.temperature")).averages)

            MetricChart(
                chart: "sensors.power",
                title: "Power draw",
                sources: [.init(metric: MonitorHub.Metric.power, color: look.secondary,
                                label: "System", format: { Format.power($0) })],
                shape: .columns,
                autoScale: true,
                height: 32,
                appearance: look,
                value: sensors.systemPower.map { Format.power($0) },
                gridLines: [0.5]
            )

            if !sensors.fans.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 14) {
                    ForEach(sensors.fans) { fan in
                        VStack(spacing: 4) {
                            RingGauge(fraction: fan.loadFraction,
                                      color: look.secondary,
                                      lineWidth: 5,
                                      diameter: 50,
                                      label: "\(Int(fan.rpm))",
                                      caption: "rpm")
                            Text(fan.name)
                                .font(.system(size: 10, weight: .medium))
                            Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            if sensors.storageTemperature != nil {
                MetricChart(
                    chart: "sensors.ssd",
                    title: "SSD temperature",
                    sources: [.init(metric: MonitorHub.Metric.ssdTemperature,
                                    color: Color(hex: "#5AC8FA"), label: "SSD",
                                    format: { Format.temperature($0, unit: settings.temperatureUnit,
                                                                 decimals: 1) })],
                    shape: .area,
                    ceiling: 90,
                    floorValue: 20,
                    height: 40,
                    appearance: look,
                    value: sensors.storageTemperature.map {
                        Format.temperature($0, unit: settings.temperatureUnit, decimals: 1)
                    },
                    caption: "20–90 °C"
                )
            }

            if let batteryTemperature = sensors.batteryTemperature {
                let cells = sensors.readings.filter { $0.group == .battery }
                MetricChart(
                    chart: "sensors.batteryTemperature",
                    title: "Battery temperature",
                    sources: [.init(metric: MonitorHub.Metric.batteryTemperature,
                                    color: Color(hex: "#30D158"), label: "Battery",
                                    format: { Format.temperature($0, unit: settings.temperatureUnit,
                                                                 decimals: 1) })],
                    shape: .area,
                    ceiling: 60,
                    floorValue: 10,
                    height: 40,
                    appearance: look,
                    value: Format.temperature(batteryTemperature, unit: settings.temperatureUnit,
                                              decimals: 1),
                    caption: cells.count > 1
                        ? "mean of \(cells.count) cells, \(cellRange(cells))" : "10–60 °C"
                )
            }

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .sensors) })
        }
    }

    /// The spread across the pack says more than the mean alone: cells that
    /// disagree by several degrees are worth noticing.
    private func cellRange(_ cells: [SensorReading]) -> String {
        let values = cells.map(\.value)
        guard let low = values.min(), let high = values.max() else { return "" }
        return "\(Format.temperature(low, unit: settings.temperatureUnit))–"
             + "\(Format.temperature(high, unit: settings.temperatureUnit))"
    }
}

/// Clock speeds for each CPU cluster and the GPU.
///
/// Apple Silicon reports no current frequency; these are the residency-weighted
/// averages over the last sampling interval, which is the only figure the
/// hardware makes available.
struct ClockSection: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let clocks = hub.snapshot.frequency
        let hasAny = clocks.maximumEfficiencyMHz > 0 || clocks.maximumPerformanceMHz > 0

        if hasAny {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Frequency")
                ClockRow(name: "\(hub.efficiencyClusterName) cores",
                         megahertz: clocks.efficiencyMHz,
                         maximum: clocks.maximumEfficiencyMHz,
                         active: clocks.efficiencyActive,
                         color: .teal)
                ClockRow(name: "\(hub.performanceClusterName) cores",
                         megahertz: clocks.performanceMHz,
                         maximum: clocks.maximumPerformanceMHz,
                         active: clocks.performanceActive,
                         color: settings.graph(.cpu).primary)
                if clocks.maximumGPUMHz > 0 {
                    ClockRow(name: "GPU",
                             megahertz: clocks.gpuMHz,
                             maximum: clocks.maximumGPUMHz,
                             active: clocks.gpuActive,
                             color: settings.graph(.gpu).primary)
                }
            }
        }
    }
}

struct ClockRow: View {
    let name: String
    let megahertz: Double?
    let maximum: Double
    let active: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)

            // The bar is the clock against this unit's own ceiling; the
            // dimmer part behind it is how much of the interval it ran at all.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color.opacity(0.25))
                        .frame(width: geometry.size.width * active.clamped(to: 0...1))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 5)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(megahertz == nil ? .secondary : .primary)
        }
        .help(megahertz == nil
              ? "\(name) stayed idle over the last sample"
              : "\(name): \(label) of \(String(format: "%.2f GHz", maximum / 1000)) maximum, "
                + "running \(Format.percent(active)) of the interval")
    }

    private var fraction: Double {
        guard let megahertz, maximum > 0 else { return 0 }
        return (megahertz / maximum).clamped(to: 0...1)
    }

    private var label: String {
        guard let megahertz else { return "idle" }
        return String(format: "%.2f GHz", megahertz / 1000)
    }
}

// MARK: - Battery

struct BatteryPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let battery = hub.snapshot.battery
        let look = settings.graph(.battery)

        Panel {
            PanelHeader(title: "Battery", subtitle: statusLine(battery), symbol: "battery.75percent")

            if battery.isPresent {
                HStack(alignment: .center, spacing: 14) {
                    RingGauge(fraction: battery.charge,
                              color: chargeColor(battery),
                              label: "\(battery.chargePercent)%",
                              caption: battery.isCharging ? "charging" : "charge")
                    VStack(alignment: .leading, spacing: 3) {
                        if let time = battery.isCharging ? battery.timeToFull : battery.timeToEmpty {
                            StatRow(label: battery.isCharging ? "Until full" : "Remaining",
                                    value: Format.duration(time))
                        }
                        if let health = battery.health {
                            StatRow(label: "Health", value: Format.percent(health, decimals: 1),
                                    valueColor: health < 0.8 ? .orange : .primary)
                        }
                        if let cycles = battery.cycleCount {
                            StatRow(label: "Cycles",
                                    value: battery.designCycleCount.map { "\(cycles) of \($0)" } ?? "\(cycles)")
                        }
                        if let drain = battery.drainWatts {
                            StatRow(label: "Drain", value: Format.power(drain), valueColor: .orange)
                        }
                    }
                }

                if battery.isOptimizedChargingPaused {
                    Text("Charging is paused by battery health management.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                MetricChart(
                    chart: "battery.charge",
                    title: "Charge",
                    sources: [.init(metric: MonitorHub.Metric.battery, color: look.primary,
                                    label: "Charge", format: { Format.percent($0) })],
                    shape: look.shape == .stacked || look.shape == .mirrored ? .area : look.shape,
                    ceiling: 1,
                    height: 40,
                    appearance: look,
                    value: "\(battery.chargePercent)%"
                )

                Divider()

                VStack(spacing: 2) {
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
        Panel(width: 290) {
            PanelHeader(title: "Time", subtitle: TimeZone.current.identifier, symbol: "clock")

            Text(clock.value, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(localTime(clock.value, zone: .current))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if settings.timeZones.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
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

            Divider()
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

        Panel(width: 330) {
            PanelHeader(title: hub.hardware.modelIdentifier,
                        subtitle: "\(hub.hardware.chip) · macOS \(hub.hardware.osVersion)",
                        symbol: "square.grid.2x2")

            HStack(spacing: 6) {
                ring("CPU", snapshot.cpu.total, settings.graph(.cpu))
                ring("Memory", snapshot.memory.usedFraction, settings.graph(.memory),
                     load: snapshot.memory.pressureFraction)
                ring("GPU", snapshot.gpu.utilization, settings.graph(.gpu))
                if snapshot.battery.isPresent {
                    ring("Battery", snapshot.battery.charge, settings.graph(.battery), load: 0)
                }
            }

            MetricChart(
                chart: "combined.cpu",
                title: "CPU",
                sources: [.init(metric: MonitorHub.Metric.cpu, color: settings.graph(.cpu).primary,
                                label: "CPU", format: { Format.percent($0, decimals: 1) })],
                shape: .area,
                ceiling: 1,
                height: 34,
                appearance: settings.graph(.cpu),
                value: Format.percent(snapshot.cpu.total),
                gridLines: [0.5]
            )

            MetricChart(
                chart: "combined.network",
                title: "Network",
                sources: [.init(metric: MonitorHub.Metric.networkDown,
                                color: settings.graph(.network).primary,
                                label: "Down", format: { Format.rate($0) }),
                          .init(metric: MonitorHub.Metric.networkUp,
                                color: settings.graph(.network).secondary,
                                label: "Up", format: { Format.rate($0) })],
                shape: .mirrored,
                autoScale: true,
                height: 40,
                appearance: settings.graph(.network),
                value: "↓ \(Format.rate(snapshot.network.downloadRate))  ↑ \(Format.rate(snapshot.network.uploadRate))"
            )

            Divider()

            VStack(spacing: 2) {
                StatRow(label: "Disk",
                        value: "R \(Format.rate(snapshot.disk.activity.readRate))  W \(Format.rate(snapshot.disk.activity.writeRate))")
                if let volume = snapshot.disk.bootVolume {
                    StatRow(label: volume.name, value: "\(Format.bytes(volume.free)) free")
                }
                if let temperature = snapshot.sensors.socTemperature {
                    StatRow(label: "CPU die",
                            value: Format.temperature(temperature, unit: settings.temperatureUnit, decimals: 1))
                }
                if let fan = snapshot.sensors.fans.first {
                    StatRow(label: fan.name, value: "\(Int(fan.rpm)) rpm")
                }
                if let power = snapshot.sensors.systemPower {
                    StatRow(label: "System power", value: Format.power(power))
                }
                StatRow(label: "Processes", value: "\(snapshot.cpu.processCount)")
                StatRow(label: "Uptime", value: Format.duration(snapshot.cpu.uptime))
            }

            Divider()
            ProcessList(title: "Top by CPU", processes: Array(snapshot.topByCPU.prefix(5)),
                        showsMemory: false, accent: settings.graph(.cpu).primary)

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: nil) })
        }
    }

    private func ring(_ title: String, _ fraction: Double,
                      _ look: GraphAppearance, load: Double? = nil) -> some View {
        VStack(spacing: 3) {
            RingGauge(fraction: fraction,
                      color: look.valueColor(load: load ?? fraction),
                      lineWidth: 5,
                      diameter: 54,
                      label: Format.percent(fraction))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
