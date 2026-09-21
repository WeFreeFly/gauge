import SwiftUI
import GaugeKit

/// Chooses what the Sensors menu bar item shows.
///
/// Readings this Mac does not report are listed but disabled, so it is clear
/// they exist and why they are not on offer, rather than silently absent.
struct SensorMenubarPicker: View {
    enum Style { case compact, full }

    var style: Style = .compact

    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    private var sensors: SensorSnapshot { hub.snapshot.sensors }

    private func isAvailable(_ item: SensorMenubarItem) -> Bool {
        if item.requiresCalibration, settings.sensorCalibration == nil { return false }
        return item.value(from: sensors, unit: settings.temperatureUnit) != nil
    }

    private func title(_ item: SensorMenubarItem) -> String {
        item.title(performanceCluster: hub.performanceClusterName,
                   efficiencyCluster: hub.efficiencyClusterName)
    }

    private var summary: String {
        let chosen = settings.sensorMenubarItems
        guard !chosen.isEmpty else { return "nothing" }
        return chosen.map { title($0) }.joined(separator: " · ")
    }

    var body: some View {
        switch style {
        case .compact: compact
        case .full: full
        }
    }

    // MARK: Compact — sits in the dropdown

    private var compact: some View {
        HStack(spacing: 6) {
            Text("MENU BAR")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.5)
            Menu {
                menuItems
            } label: {
                HStack(spacing: 3) {
                    Text(summary)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Choose what the Sensors menu bar item shows")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(SensorMenubarItem.allCases) { item in
            Button {
                settings.toggleSensorMenubarItem(item)
            } label: {
                if settings.sensorMenubarItems.contains(item) {
                    Label(title(item), systemImage: "checkmark")
                } else {
                    Text(title(item))
                }
            }
            .disabled(!isAvailable(item) && !settings.sensorMenubarItems.contains(item))
        }
        Divider()
        Text("Up to \(SensorMenubarItem.maximumSelected) at a time")
    }

    // MARK: Full — sits in settings

    private var full: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick up to \(SensorMenubarItem.maximumSelected) readings. One shows at full "
               + "size; two stack at a smaller one. Greyed-out readings are not reported by "
               + "this Mac.")
                .settingsFootnote()

            ForEach(SensorMenubarItem.allCases) { item in
                let chosen = settings.sensorMenubarItems.contains(item)
                let available = isAvailable(item)
                Toggle(isOn: Binding(
                    get: { chosen },
                    set: { _ in settings.toggleSensorMenubarItem(item) }
                )) {
                    HStack(spacing: 6) {
                        Text(title(item))
                            .font(.system(size: 11))
                        Spacer(minLength: 8)
                        if let value = item.formatted(from: sensors, unit: settings.temperatureUnit) {
                            Text(item.shortPrefix + value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else if item.requiresCalibration, settings.sensorCalibration == nil {
                            Text("needs calibration")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("not reported")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!available && !chosen)
            }

            HStack {
                Button("Reset to default") {
                    settings.sensorMenubarItems = SensorMenubarItem.standard
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}
