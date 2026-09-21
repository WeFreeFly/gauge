// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import GaugeKit

struct ModulePanelView: View {
    let module: ModuleID

    var body: some View {
        switch module {
        case .cpu:      CPUPanel()
        case .gpu:      GPUPanel()
        case .memory:   MemoryPanel()
        case .disks:    DisksPanel()
        case .network:  NetworkPanel()
        case .sensors:  SensorsPanel()
        case .battery:  BatteryPanel()
        case .time:     TimePanel()
        case .weather:  WeatherPanel()
        case .combined: CombinedPanel()
        }
    }
}

/// The oversized reading at the top of a dropdown, with up to two supporting
/// figures on the right.
struct HeroValue: View {
    let value: String
    var caption: String?
    var color: Color = .primary
    var trailing: [(String, String)] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(trailing.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        Text(trailing[index].0)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(trailing[index].1)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - CPU

struct CPUPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let cpu = hub.snapshot.cpu
        let series = hub.series
        let look = settings.graph(.cpu)

        Panel {
            PanelHeader(title: "CPU",
                        subtitle: "\(hub.hardware.chip) · \(hub.hardware.performanceCores) \(hub.performanceClusterName)"
                                + " + \(hub.hardware.efficiencyCores) \(hub.efficiencyClusterName)",
                        symbol: "cpu")

            HeroValue(value: Format.percent(cpu.total),
                      caption: "in use",
                      color: look.valueColor(load: cpu.total),
                      trailing: [
                        (hub.performanceClusterName, Format.percent(cpu.performanceLoad)),
                        (hub.efficiencyClusterName, Format.percent(cpu.efficiencyLoad)),
                      ])

            ClockSection()

            MetricChart(
                chart: "cpu.usage",
                title: "Usage",
                sources: look.shape == .stacked
                    ? [.init(metric: MonitorHub.Metric.cpuUser, color: look.primary,
                             label: "User", format: { Format.percent($0, decimals: 1) }),
                       .init(metric: MonitorHub.Metric.cpuSystem, color: look.secondary,
                             label: "System", format: { Format.percent($0, decimals: 1) })]
                    : [.init(metric: MonitorHub.Metric.cpu, color: look.primary,
                             label: "CPU", format: { Format.percent($0, decimals: 1) })],
                shape: look.shape,
                ceiling: 1,
                height: 58,
                appearance: look,
                value: Format.percent(cpu.total),
                valueColor: look.valueColor(load: cpu.total)
            )

            if settings.showPerCoreGraph, !cpu.cores.isEmpty {
                let coreRange = settings.chartRange("cpu.cores")
                let coreHistories = cpu.cores.map {
                    hub.series(MonitorHub.Metric.core($0.id), range: coreRange, points: 120).averages
                }
                GraphSection(title: "Per core",
                             value: "\(cpu.cores.count) cores",
                             caption: " ",
                             chart: "cpu.cores") {
                    CoreHistoryGrid(cores: cpu.cores,
                                    histories: coreHistories,
                                    columns: cpu.cores.count > 8 ? 5 : 4) { core in
                        core.kind == .efficiency ? Color.teal : look.primary
                    }
                }
            }

            MetricChart(
                chart: "cpu.load",
                title: "Load average",
                sources: [.init(metric: MonitorHub.Metric.load, color: look.secondary,
                                label: "Load", format: { String(format: "%.2f", $0) })],
                shape: look.shape == .stacked ? .area : look.shape,
                ceiling: Double(hub.hardware.coreCount),
                autoScale: true,
                height: 34,
                appearance: look,
                value: String(format: "%.2f", cpu.loadAverage.one),
                gridLines: [0.5]
            )

            Divider()

            VStack(spacing: 2) {
                StatRow(label: "User", value: Format.percent(cpu.user, decimals: 1), valueColor: look.primary)
                StatRow(label: "System", value: Format.percent(cpu.system, decimals: 1), valueColor: look.secondary)
                StatRow(label: "Idle", value: Format.percent(cpu.idle, decimals: 1))
                StatRow(label: "\(hub.performanceClusterName) cores",
                        value: "\(hub.hardware.performanceCores) · \(Format.percent(cpu.performanceLoad, decimals: 1))")
                StatRow(label: "\(hub.efficiencyClusterName) cores",
                        value: "\(hub.hardware.efficiencyCores) · \(Format.percent(cpu.efficiencyLoad, decimals: 1))")
                StatRow(label: "Load average",
                        value: String(format: "%.2f  %.2f  %.2f",
                                      cpu.loadAverage.one, cpu.loadAverage.five, cpu.loadAverage.fifteen))
                StatRow(label: "Processes", value: "\(cpu.processCount) · \(cpu.threadCount) threads")
                StatRow(label: "Uptime", value: Format.duration(cpu.uptime))
            }

            Divider()
            ProcessList(title: "Top by CPU", processes: hub.snapshot.topByCPU,
                        showsMemory: false, accent: look.primary)

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .cpu) })
        }
    }
}

// MARK: - GPU

struct GPUPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let gpu = hub.snapshot.gpu
        let look = settings.graph(.gpu)

        Panel {
            PanelHeader(title: "GPU", subtitle: gpu.isAvailable ? gpu.name : nil, symbol: "display")

            if gpu.isAvailable {
                HStack(alignment: .center, spacing: 14) {
                    RingGauge(fraction: gpu.utilization,
                              color: look.valueColor(load: gpu.utilization),
                              label: Format.percent(gpu.utilization),
                              caption: "device")
                    VStack(alignment: .leading, spacing: 4) {
                        StatRow(label: "Renderer", value: Format.percent(gpu.rendererUtilization, decimals: 1))
                        StatRow(label: "Tiler", value: Format.percent(gpu.tilerUtilization, decimals: 1))
                        StatRow(label: "In use", value: Format.bytes(gpu.inUseMemory))
                    }
                }

                MetricChart(
                    chart: "gpu.utilisation",
                    title: "Utilisation",
                    sources: [.init(metric: MonitorHub.Metric.gpu, color: look.primary,
                                    label: "GPU", format: { Format.percent($0, decimals: 1) })],
                    shape: look.shape == .stacked ? .area : look.shape,
                    ceiling: 1,
                    height: 52,
                    appearance: look,
                    value: Format.percent(gpu.utilization),
                    valueColor: look.valueColor(load: gpu.utilization)
                )

                Divider()

                VStack(spacing: 2) {
                    StatRow(label: "Memory allocated", value: Format.bytes(gpu.allocatedMemory))
                    StatRow(label: "Peak utilisation",
                            value: Format.percent(hub.series.gpu.max() ?? 0))
                }

                Text("Apple Silicon shares one memory pool, so GPU memory is drawn from system RAM.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No accelerator is reporting statistics.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .gpu) })
        }
    }
}

// MARK: - Memory

struct MemoryPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let memory = hub.snapshot.memory
        let series = hub.series
        let look = settings.graph(.memory)
        let compressedColor = Color(hex: "#BF5AF2")

        Panel {
            PanelHeader(title: "Memory",
                        subtitle: "\(Format.bytes(memory.total)) installed",
                        symbol: "memorychip")

            HeroValue(value: Format.bytes(memory.used),
                      caption: "used",
                      color: look.valueColor(load: memory.pressureFraction),
                      trailing: [
                        ("pressure", memory.pressure.label),
                        ("free", Format.bytes(memory.free)),
                      ])

            SegmentedMeter(segments: [
                .init(value: memory.appMemory, color: look.primary, label: "App"),
                .init(value: memory.wired, color: look.secondary, label: "Wired"),
                .init(value: memory.compressed, color: compressedColor, label: "Compressed"),
                .init(value: memory.cachedFiles, color: Color.primary.opacity(0.22), label: "Cached"),
            ], total: memory.total)

            MetricChart(
                chart: "memory.used",
                title: "Memory used",
                sources: look.shape == .stacked
                    ? [.init(metric: MonitorHub.Metric.memoryApp, color: look.primary,
                             label: "App", format: { Format.bytes($0) }),
                       .init(metric: MonitorHub.Metric.memoryWired, color: look.secondary,
                             label: "Wired", format: { Format.bytes($0) }),
                       .init(metric: MonitorHub.Metric.memoryCompressed, color: compressedColor,
                             label: "Compressed", format: { Format.bytes($0) })]
                    : [.init(metric: MonitorHub.Metric.memory, color: look.primary,
                             label: "Used", format: { Format.percent($0, decimals: 1) })],
                shape: look.shape,
                ceiling: look.shape == .stacked ? memory.total : 1,
                height: 56,
                appearance: look,
                value: Format.percent(memory.usedFraction)
            )

            MetricChart(
                chart: "memory.swap",
                title: "Swap",
                sources: [.init(metric: MonitorHub.Metric.swap, color: compressedColor,
                                label: "Swap", format: { Format.bytes($0) })],
                shape: look.shape == .stacked ? .area : look.shape,
                ceiling: memory.swapTotal,
                autoScale: memory.swapTotal <= 0,
                height: 30,
                appearance: look,
                value: Format.bytes(memory.swapUsed),
                valueColor: memory.swapUsed > 1_073_741_824 ? .orange : .primary,
                caption: "of \(Format.bytes(memory.swapTotal))",
                gridLines: [0.5]
            )

            Divider()

            VStack(spacing: 2) {
                StatRow(label: "App memory", value: Format.bytes(memory.appMemory), valueColor: look.primary)
                StatRow(label: "Wired", value: Format.bytes(memory.wired), valueColor: look.secondary)
                StatRow(label: "Compressed", value: Format.bytes(memory.compressed), valueColor: compressedColor)
                StatRow(label: "Cached files", value: Format.bytes(memory.cachedFiles))
                StatRow(label: "Free", value: Format.bytes(memory.free))
                StatRow(label: "Swap ins / outs", value: "\(memory.swapIns) / \(memory.swapOuts)")
            }

            Divider()
            ProcessList(title: "Top by memory", processes: hub.snapshot.topByMemory,
                        showsMemory: true, accent: look.primary)

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .memory) })
        }
    }
}

// MARK: - Disks

struct DisksPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let disk = hub.snapshot.disk
        let series = hub.series
        let look = settings.graph(.disks)

        Panel {
            PanelHeader(title: "Disks", subtitle: "\(disk.volumes.count) mounted", symbol: "internaldrive")

            if let boot = disk.bootVolume {
                HStack(alignment: .center, spacing: 14) {
                    RingGauge(fraction: boot.usedFraction,
                              color: Color.load(boot.usedFraction),
                              label: Format.percent(boot.usedFraction),
                              caption: "used")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(boot.name).font(.system(size: 12, weight: .medium))
                        Text("\(Format.bytes(boot.free)) free of \(Format.bytes(boot.total))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Label(Format.rate(disk.activity.readRate), systemImage: "arrow.down")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(look.primary)
                            Label(Format.rate(disk.activity.writeRate), systemImage: "arrow.up")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(look.secondary)
                        }
                        .padding(.top, 1)
                    }
                    Spacer(minLength: 0)
                }
            }

            MetricChart(
                chart: "disk.activity",
                title: "Activity",
                sources: [.init(metric: MonitorHub.Metric.diskRead, color: look.primary,
                                label: "Read", format: { Format.rate($0) }),
                          .init(metric: MonitorHub.Metric.diskWrite, color: look.secondary,
                                label: "Write", format: { Format.rate($0) })],
                shape: look.shape,
                autoScale: true,
                height: 56,
                appearance: look,
                value: "R \(Format.rate(disk.activity.readRate))  W \(Format.rate(disk.activity.writeRate))"
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Volumes")
                ForEach(disk.volumes) { volume in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(volume.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(Format.bytes(volume.free)) free")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        BarMeter(fraction: volume.usedFraction, color: Color.load(volume.usedFraction))
                        Text("\(Format.bytes(volume.used)) of \(Format.bytes(volume.total)) · \(volume.path)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()

            VStack(spacing: 2) {
                StatRow(label: "Read since boot", value: Format.bytes(disk.activity.readTotal))
                StatRow(label: "Written since boot", value: Format.bytes(disk.activity.writeTotal))
                StatRow(label: "Operations",
                        value: "\(disk.activity.readOperations) R · \(disk.activity.writeOperations) W")
            }

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .disks) })
        }
    }
}
