import SwiftUI
import GaugeKit

struct ModulePanelView: View {
    let module: ModuleID
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

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

// MARK: - CPU

struct CPUPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let cpu = hub.snapshot.cpu
        let look = settings.graph(.cpu)
        Panel {
            PanelHeader(title: "CPU",
                        subtitle: "\(hub.hardware.chip) · \(hub.hardware.performanceCores) \(hub.performanceClusterName)"
                                + " + \(hub.hardware.efficiencyCores) \(hub.efficiencyClusterName)",
                        symbol: "cpu")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.percent(cpu.total))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(look.valueColor(load: cpu.total))
                Text("in use")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(hub.performanceClusterName) \(Format.percent(cpu.performanceLoad))"
                       + "   \(hub.efficiencyClusterName) \(Format.percent(cpu.efficiencyLoad))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("load \(String(format: "%.2f", cpu.loadAverage.one))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 3) {
                Sparkline(values: hub.series.cpu, ceiling: 1, color: look.primary,
                          secondaryColor: look.secondary, height: 50, appearance: look)
                GraphCaption()
            }

            if settings.showPerCoreGraph, !cpu.cores.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Per core")
                    CoreGrid(cores: cpu.cores)
                }
            }

            VStack(spacing: 4) {
                StatRow(label: "User", value: Format.percent(cpu.user, decimals: 1))
                StatRow(label: "System", value: Format.percent(cpu.system, decimals: 1))
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
            ProcessList(title: "Top by CPU", processes: hub.snapshot.topByCPU, showsMemory: false)

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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.percent(gpu.utilization))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(look.valueColor(load: gpu.utilization))
                    Text("device utilisation")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(spacing: 3) {
                    Sparkline(values: hub.series.gpu, ceiling: 1, color: look.primary,
                              secondaryColor: look.secondary, height: 50, appearance: look)
                    GraphCaption()
                }

                VStack(spacing: 4) {
                    StatRow(label: "Renderer", value: Format.percent(gpu.rendererUtilization, decimals: 1))
                    StatRow(label: "Tiler", value: Format.percent(gpu.tilerUtilization, decimals: 1))
                    StatRow(label: "Memory in use", value: Format.bytes(gpu.inUseMemory))
                    StatRow(label: "Memory allocated", value: Format.bytes(gpu.allocatedMemory))
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
        let look = settings.graph(.memory)
        Panel {
            PanelHeader(title: "Memory",
                        subtitle: "\(Format.bytes(memory.total)) installed",
                        symbol: "memorychip")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(memory.used))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(memory.pressure.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pressureColor(memory.pressure))
            }

            SegmentedMeter(segments: [
                .init(value: memory.appMemory, color: .blue, label: "App"),
                .init(value: memory.wired, color: .orange, label: "Wired"),
                .init(value: memory.compressed, color: .purple, label: "Compressed"),
                .init(value: memory.cachedFiles, color: Color.primary.opacity(0.25), label: "Cached"),
            ], total: memory.total)

            VStack(spacing: 3) {
                Sparkline(values: hub.series.memory, ceiling: 1, color: look.primary,
                          secondaryColor: look.secondary, height: 44, appearance: look)
                GraphCaption()
            }

            VStack(spacing: 4) {
                StatRow(label: "App memory", value: Format.bytes(memory.appMemory), valueColor: .blue)
                StatRow(label: "Wired", value: Format.bytes(memory.wired), valueColor: .orange)
                StatRow(label: "Compressed", value: Format.bytes(memory.compressed), valueColor: .purple)
                StatRow(label: "Cached files", value: Format.bytes(memory.cachedFiles))
                StatRow(label: "Free", value: Format.bytes(memory.free))
                Divider().padding(.vertical, 1)
                StatRow(label: "Swap used",
                        value: "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))",
                        valueColor: memory.swapUsed > 1_073_741_824 ? .orange : .primary)
                StatRow(label: "Swap ins / outs", value: "\(memory.swapIns) / \(memory.swapOuts)")
            }

            Divider()
            ProcessList(title: "Top by memory", processes: hub.snapshot.topByMemory, showsMemory: true)

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .memory) })
        }
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

// MARK: - Disks

struct DisksPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let disk = hub.snapshot.disk
        let look = settings.graph(.disks)
        Panel {
            PanelHeader(title: "Disks", subtitle: "\(disk.volumes.count) mounted", symbol: "internaldrive")

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Read").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Format.rate(disk.activity.readRate))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(look.primary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Write").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Format.rate(disk.activity.writeRate))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(look.secondary)
                }
                Spacer()
            }

            VStack(spacing: 3) {
                Sparkline(values: hub.series.diskRead, secondary: hub.series.diskWrite,
                          color: look.primary, secondaryColor: look.secondary,
                          height: 44, appearance: look)
                GraphCaption(trailing: "peak \(Format.rate(max(hub.series.diskRead.max() ?? 0, hub.series.diskWrite.max() ?? 0)))   ")
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(disk.volumes) { volume in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(volume.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if volume.isRemovable {
                                Image(systemName: "eject")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            Text("\(Format.bytes(volume.free)) free")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        BarMeter(fraction: volume.usedFraction, color: Color.load(volume.usedFraction))
                        Text("\(Format.bytes(volume.used)) of \(Format.bytes(volume.total)) used")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            VStack(spacing: 4) {
                StatRow(label: "Read since boot", value: Format.bytes(disk.activity.readTotal))
                StatRow(label: "Written since boot", value: Format.bytes(disk.activity.writeTotal))
            }

            PanelFooter(onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .disks) })
        }
    }
}
