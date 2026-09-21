import AppKit
import GaugeKit

/// Turns a sampling pass into the one-glance summary each module shows.
@MainActor
enum MenubarContentBuilder {
    static func content(for module: ModuleID, hub: MonitorHub) -> MenubarContent {
        let snapshot = hub.snapshot
        let series = hub.series
        let settings = hub.settings
        var content = MenubarContent()
        content.appearance = settings.graph(module)
        content.symbolName = module.symbolName

        switch module {
        case .cpu:
            content.lines = [Format.percent(snapshot.cpu.total)]
            content.series = series.cpu
            content.seriesMaximum = 1
            content.fraction = snapshot.cpu.total
            content.loadFraction = snapshot.cpu.total
            return content

        case .gpu:
            content.lines = [Format.percent(snapshot.gpu.utilization)]
            content.series = series.gpu
            content.seriesMaximum = 1
            content.fraction = snapshot.gpu.utilization
            content.loadFraction = snapshot.gpu.utilization
            return content

        case .memory:
            content.lines = [Format.percent(snapshot.memory.usedFraction)]
            content.series = series.memory
            content.seriesMaximum = 1
            content.fraction = snapshot.memory.usedFraction
            // Pressure, not raw usage, is what should look alarming.
            content.loadFraction = snapshot.memory.pressureFraction
            return content

        case .disks:
            let activity = snapshot.disk.activity
            content.lines = [
                "R \(rate(activity.readRate, bits: false))",
                "W \(rate(activity.writeRate, bits: false))",
            ]
            content.series = series.diskRead
            content.secondarySeries = series.diskWrite
            return content

        case .network:
            let bits = settings.networkUnitBits
            content.lines = [
                "↓ \(rate(snapshot.network.downloadRate, bits: bits))",
                "↑ \(rate(snapshot.network.uploadRate, bits: bits))",
            ]
            content.series = series.networkDown
            content.secondarySeries = series.networkUp
            return content

        case .sensors:
            // Which readings appear here is the user's choice; anything this
            // Mac does not report is skipped rather than shown as a dash.
            let chosen = settings.sensorMenubarItems
            var lines: [String] = []
            for item in chosen.prefix(SensorMenubarItem.maximumSelected) {
                guard let text = item.formatted(from: snapshot.sensors,
                                                unit: settings.temperatureUnit) else { continue }
                lines.append(item.shortPrefix + text)
            }
            content.lines = lines.isEmpty ? ["—"] : lines
            content.series = series.socTemperature
            // A fixed 0–100 °C window keeps the trace comparable over time.
            content.seriesMaximum = 100
            // The first chosen reading decides the colour, when it has a scale.
            content.loadFraction = chosen.first?.loadFraction(from: snapshot.sensors)
            return content

        case .battery:
            let battery = snapshot.battery
            content.lines = battery.isPresent ? ["\(battery.chargePercent)%"] : ["AC"]
            content.fraction = battery.charge
            content.symbolName = batterySymbol(battery)
            // A battery below a fifth should look wrong whatever colour the
            // user picked for the module.
            if battery.isPresent, !battery.isCharging, battery.charge < 0.2 {
                content.appearance.usesLoadColor = true
                content.loadFraction = 1 - battery.charge
            }
            return content

        case .time:
            let formatter = DateFormatter()
            formatter.dateFormat = settings.timeFormat
            content.lines = [formatter.string(from: Date())]
            content.monospacedDigits = true
            return content

        case .weather:
            if let weather = hub.weather {
                content.lines = [Format.temperature(weather.now.temperature, unit: settings.temperatureUnit)]
                content.symbolName = weather.now.condition.symbolName
            } else {
                content.lines = []
                content.symbolName = settings.weatherEnabled ? "cloud.sun" : "cloud.slash"
            }
            return content

        case .combined:
            content.lines = [
                "\(Format.percent(snapshot.cpu.total))  \(Format.percent(snapshot.memory.usedFraction))",
                "↓\(rate(snapshot.network.downloadRate, bits: settings.networkUnitBits))"
                + " ↑\(rate(snapshot.network.uploadRate, bits: settings.networkUnitBits))",
            ]
            content.series = series.cpu
            content.seriesMaximum = 1
            content.loadFraction = snapshot.cpu.total
            return content
        }
    }

    /// Menu bar width is scarce, so rates lose the "/s" and keep one letter.
    private static func rate(_ bytesPerSecond: Double, bits: Bool) -> String {
        let value = bits ? bytesPerSecond * 8 : bytesPerSecond
        let units = bits ? ["b", "K", "M", "G"] : ["B", "K", "M", "G"]
        var scaled = max(0, value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        let places = scaled >= 10 || unit == 0 ? 0 : 1
        return String(format: "%.\(places)f%@", scaled, units[unit])
    }

    private static func batterySymbol(_ battery: BatterySnapshot) -> String {
        guard battery.isPresent else { return "powerplug" }
        if battery.isCharging { return "battery.100percent.bolt" }
        return switch battery.charge {
        case ..<0.1: "battery.0percent"
        case ..<0.3: "battery.25percent"
        case ..<0.6: "battery.50percent"
        case ..<0.85: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
